import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../models/message.dart';

enum ExternalChatSource { chatGpt, claude, gemini, grok, generic, markdown }

extension ExternalChatSourceLabel on ExternalChatSource {
  String get displayName => switch (this) {
    ExternalChatSource.chatGpt => 'ChatGPT',
    ExternalChatSource.claude => 'Claude',
    ExternalChatSource.gemini => 'Gemini',
    ExternalChatSource.grok => 'Grok',
    ExternalChatSource.generic => 'JSON',
    ExternalChatSource.markdown => 'Markdown',
  };
}

class ExternalImportMessage {
  const ExternalImportMessage({
    required this.isUser,
    required this.text,
    this.createdAt,
  });

  final bool isUser;
  final String text;
  final DateTime? createdAt;
}

class ExternalImportConversation {
  const ExternalImportConversation({
    required this.sourceId,
    required this.title,
    required this.messages,
  });

  final String sourceId;
  final String title;
  final List<ExternalImportMessage> messages;
}

class ExternalImportPreview {
  const ExternalImportPreview({
    required this.source,
    required this.conversations,
    this.warnings = const <String>[],
    this.referenceDocument,
  });

  final ExternalChatSource source;
  final List<ExternalImportConversation> conversations;
  final List<String> warnings;

  /// A Markdown document without reliable speaker boundaries is kept as a
  /// reference preview. It is never silently converted into invented chat.
  final String? referenceDocument;

  int get messageCount => conversations.fold<int>(
    0,
    (total, conversation) => total + conversation.messages.length,
  );

  bool get canImport =>
      conversations.any((conversation) => conversation.messages.isNotEmpty);
}

class ExternalImportResult {
  const ExternalImportResult({
    required this.importedConversations,
    required this.updatedConversations,
    required this.importedMessages,
    required this.skippedDuplicates,
  });

  final int importedConversations;
  final int updatedConversations;
  final int importedMessages;
  final int skippedDuplicates;
}

/// Additive importer for third-party chat exports.
///
/// It intentionally does not create memories, summaries, relationship rows,
/// or story states. Imported windows become ordinary source material and the
/// user remains in control of when Holt summarizes them.
class ExternalChatImportService {
  static const int maxFileBytes = 128 * 1024 * 1024;

  static Future<ExternalImportPreview> parseFile(String path) =>
      Isolate.run(() => _parseFileInBackground(path));

  static Future<ExternalImportPreview> _parseFileInBackground(
    String path,
  ) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FormatException('The selected file no longer exists.');
    }
    final size = await file.length();
    if (size > maxFileBytes) {
      throw const FormatException(
        'The selected file is larger than 128 MB. Split it before importing.',
      );
    }
    final text = await file.readAsString();
    return parseText(text, fileName: file.uri.pathSegments.last);
  }

  static ExternalImportPreview parseText(String raw, {String fileName = ''}) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const FormatException('The selected file is empty.');
    }
    final looksLikeMarkdown = fileName.toLowerCase().endsWith('.md');
    if (!looksLikeMarkdown) {
      try {
        return _parseJson(jsonDecode(text));
      } on JsonUnsupportedObjectError {
        rethrow;
      } on FormatException {
        if (fileName.toLowerCase().endsWith('.json')) rethrow;
      } catch (_) {
        if (fileName.toLowerCase().endsWith('.json')) {
          throw const FormatException('This JSON export could not be read.');
        }
      }
    }
    return _parseMarkdown(text);
  }

  static Future<ExternalImportResult> importPreview({
    required ExternalImportPreview preview,
    required String characterId,
    required ContextMode contextMode,
    String continuityId = 'main',
  }) async {
    if (!preview.canImport) {
      throw const FormatException('No importable conversations were found.');
    }
    final normalizedCharacterId = characterId.trim();
    final normalizedContinuityId = continuityId.trim();
    if (normalizedCharacterId.isEmpty || normalizedContinuityId.isEmpty) {
      throw const FormatException('Character and storyline are required.');
    }
    final db = await DatabaseHelper.database;
    final character = await db.query(
      'characters',
      columns: const <String>['id'],
      where: 'id = ?',
      whereArgs: <Object?>[normalizedCharacterId],
      limit: 1,
    );
    if (character.isEmpty) {
      throw const FormatException('The selected character no longer exists.');
    }
    if (contextMode == ContextMode.rp) {
      final storyline = await db.query(
        'rp_storylines',
        columns: const <String>['id'],
        where: 'character_id = ? AND id = ? AND status = ?',
        whereArgs: <Object?>[
          normalizedCharacterId,
          normalizedContinuityId,
          'active',
        ],
        limit: 1,
      );
      if (storyline.isEmpty) {
        throw const FormatException('The selected storyline is unavailable.');
      }
    }

    var importedConversations = 0;
    var updatedConversations = 0;
    var importedMessages = 0;
    var skippedDuplicates = 0;
    await db.transaction<void>((txn) async {
      for (final sourceConversation in preview.conversations) {
        if (sourceConversation.messages.isEmpty) continue;
        final conversationId = _stableConversationId(
          source: preview.source,
          sourceConversation: sourceConversation,
          characterId: normalizedCharacterId,
          contextMode: contextMode,
          continuityId: normalizedContinuityId,
        );
        final existing = await txn.query(
          'conversations',
          columns: const <String>['id'],
          where: 'id = ?',
          whereArgs: <Object?>[conversationId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final storedMessages = await txn.query(
            'messages',
            columns: const <String>['is_user', 'text'],
            where: 'conversation_id = ?',
            whereArgs: <Object?>[conversationId],
            orderBy: 'created_at ASC, id ASC',
          );
          final prefixMatches =
              storedMessages.length <= sourceConversation.messages.length &&
              List<bool>.generate(storedMessages.length, (index) {
                final stored = storedMessages[index];
                final incoming = sourceConversation.messages[index];
                return (stored['is_user'] == 1) == incoming.isUser &&
                    stored['text']?.toString().trim() ==
                        _safeImportedText(
                          incoming.text,
                          isUser: incoming.isUser,
                        ).trim();
              }).every((matches) => matches);
          if (!prefixMatches ||
              storedMessages.length == sourceConversation.messages.length) {
            skippedDuplicates++;
            continue;
          }
          final fallbackTime =
              sourceConversation.messages
                  .map((message) => message.createdAt)
                  .whereType<DateTime>()
                  .fold<DateTime?>(
                    null,
                    (latest, value) => latest == null || value.isAfter(latest)
                        ? value
                        : latest,
                  ) ??
              DateTime.now();
          for (
            var index = storedMessages.length;
            index < sourceConversation.messages.length;
            index++
          ) {
            final imported = sourceConversation.messages[index];
            final message = Message(
              conversationId: conversationId,
              characterId: normalizedCharacterId,
              text: _safeImportedText(imported.text, isUser: imported.isUser),
              isUser: imported.isUser,
              createdAt:
                  imported.createdAt ??
                  fallbackTime.add(Duration(milliseconds: index)),
            );
            await txn.insert('messages', message.toMap());
            importedMessages++;
          }
          await txn.update(
            'conversations',
            <String, Object?>{'updated_at': fallbackTime.toIso8601String()},
            where: 'id = ?',
            whereArgs: <Object?>[conversationId],
          );
          updatedConversations++;
          continue;
        }
        final timestamps = sourceConversation.messages
            .map((message) => message.createdAt)
            .whereType<DateTime>()
            .toList(growable: false);
        final createdAt = timestamps.isEmpty
            ? DateTime.now()
            : timestamps.reduce((a, b) => a.isBefore(b) ? a : b);
        final updatedAt = timestamps.isEmpty
            ? createdAt
            : timestamps.reduce((a, b) => a.isAfter(b) ? a : b);
        final title = sourceConversation.title.trim().isEmpty
            ? preview.source.displayName
            : sourceConversation.title.trim();
        final conversation = Conversation(
          id: conversationId,
          characterId: normalizedCharacterId,
          contextMode: contextMode,
          continuityId: normalizedContinuityId,
          title: '${preview.source.displayName} · $title',
          createdAt: createdAt,
          updatedAt: updatedAt,
        );
        await txn.insert('conversations', conversation.toMap());
        for (
          var index = 0;
          index < sourceConversation.messages.length;
          index++
        ) {
          final imported = sourceConversation.messages[index];
          final message = Message(
            conversationId: conversationId,
            characterId: normalizedCharacterId,
            text: _safeImportedText(imported.text, isUser: imported.isUser),
            isUser: imported.isUser,
            createdAt:
                imported.createdAt ??
                createdAt.add(Duration(milliseconds: index)),
          );
          await txn.insert('messages', message.toMap());
          importedMessages++;
        }
        importedConversations++;
      }
    });
    return ExternalImportResult(
      importedConversations: importedConversations,
      updatedConversations: updatedConversations,
      importedMessages: importedMessages,
      skippedDuplicates: skippedDuplicates,
    );
  }

  static ExternalImportPreview _parseJson(Object? root) {
    final items = _conversationItems(root);
    if (items.isEmpty) {
      throw const FormatException('No supported conversations were found.');
    }
    final source = _detectJsonSource(items, root);
    final conversations = <ExternalImportConversation>[];
    var skipped = 0;
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final parsed =
          source == ExternalChatSource.chatGpt && item['mapping'] is Map
          ? _parseChatGptConversation(item, index)
          : _parseListConversation(item, index, source);
      if (parsed == null || parsed.messages.isEmpty) {
        skipped++;
      } else {
        conversations.add(parsed);
      }
    }
    final warnings = <String>[];
    if (skipped > 0) {
      warnings.add(
        '$skipped conversation(s) had no reliable user/assistant messages.',
      );
    }
    return ExternalImportPreview(
      source: source,
      conversations: List<ExternalImportConversation>.unmodifiable(
        conversations,
      ),
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  static List<Map<String, dynamic>> _conversationItems(Object? root) {
    if (root is List) {
      return root.whereType<Map>().map(_stringMap).toList(growable: false);
    }
    if (root is! Map) return const <Map<String, dynamic>>[];
    final map = _stringMap(root);
    for (final key in const <String>[
      'conversations',
      'chats',
      'items',
      'data',
    ]) {
      final value = map[key];
      if (value is List) {
        final rows = value
            .whereType<Map>()
            .map(_stringMap)
            .toList(growable: false);
        if (rows.isNotEmpty) return rows;
      }
    }
    if (map.containsKey('mapping') ||
        map.containsKey('messages') ||
        map.containsKey('chat_messages')) {
      return <Map<String, dynamic>>[map];
    }
    return const <Map<String, dynamic>>[];
  }

  static ExternalChatSource _detectJsonSource(
    List<Map<String, dynamic>> items,
    Object? root,
  ) {
    if (items.any((item) => item['mapping'] is Map)) {
      return ExternalChatSource.chatGpt;
    }
    if (items.any((item) => item['chat_messages'] is List)) {
      return ExternalChatSource.claude;
    }
    final markers = <String>[];
    if (root is Map) {
      final map = _stringMap(root);
      markers.addAll(
        <Object?>[
          map['source'],
          map['provider'],
          map['platform'],
          map['model'],
        ].whereType<Object>().map((value) => value.toString()),
      );
    }
    for (final item in items.take(4)) {
      markers.addAll(
        <Object?>[
          item['source'],
          item['provider'],
          item['platform'],
          item['model'],
        ].whereType<Object>().map((value) => value.toString()),
      );
    }
    final markerText = markers.join(' ').toLowerCase();
    if (markerText.contains('gemini') || markerText.contains('bard')) {
      return ExternalChatSource.gemini;
    }
    if (markerText.contains('grok') || markerText.contains('xai')) {
      return ExternalChatSource.grok;
    }
    return ExternalChatSource.generic;
  }

  static ExternalImportConversation? _parseChatGptConversation(
    Map<String, dynamic> item,
    int index,
  ) {
    final mapping = item['mapping'];
    if (mapping is! Map) return null;
    final nodes = mapping.map<String, Map<String, dynamic>>(
      (key, value) => MapEntry(
        key.toString(),
        value is Map ? _stringMap(value) : <String, dynamic>{},
      ),
    );
    final ordered = <Map<String, dynamic>>[];
    final currentNode = item['current_node']?.toString();
    if (currentNode != null && nodes.containsKey(currentNode)) {
      final reverse = <Map<String, dynamic>>[];
      final seen = <String>{};
      String? cursor = currentNode;
      while (cursor != null && seen.add(cursor)) {
        final node = nodes[cursor];
        if (node == null) break;
        reverse.add(node);
        cursor = node['parent']?.toString();
      }
      ordered.addAll(reverse.reversed);
    } else {
      ordered.addAll(nodes.values);
      ordered.sort(
        (a, b) =>
            _timestampOf(a['message']).compareTo(_timestampOf(b['message'])),
      );
    }
    final messages = ordered
        .map((node) => _parseMessage(node['message']))
        .whereType<ExternalImportMessage>()
        .toList(growable: false);
    return ExternalImportConversation(
      sourceId: _sourceId(item, index),
      title: _titleOf(item, index),
      messages: messages,
    );
  }

  static ExternalImportConversation? _parseListConversation(
    Map<String, dynamic> item,
    int index,
    ExternalChatSource source,
  ) {
    Object? rawMessages = item['messages'] ?? item['chat_messages'];
    rawMessages ??= item['turns'] ?? item['history'];
    if (rawMessages is! List) return null;
    final messages = rawMessages
        .map(_parseMessage)
        .whereType<ExternalImportMessage>()
        .toList(growable: false);
    return ExternalImportConversation(
      sourceId: _sourceId(item, index),
      title: _titleOf(item, index),
      messages: messages,
    );
  }

  static ExternalImportMessage? _parseMessage(Object? raw) {
    if (raw is! Map) return null;
    final map = _stringMap(raw);
    final role = _roleOf(map);
    if (role == null) return null;
    final text = _textOf(map).trim();
    if (text.isEmpty) return null;
    return ExternalImportMessage(
      isUser: role == 'user',
      text: text,
      createdAt: _dateTimeOf(
        map['created_at'] ??
            map['create_time'] ??
            map['timestamp'] ??
            map['time'],
      ),
    );
  }

  static String? _roleOf(Map<String, dynamic> map) {
    Object? raw = map['role'] ?? map['sender'] ?? map['speaker'];
    final author = map['author'];
    if (raw == null && author is Map) {
      raw = author['role'] ?? author['name'];
    }
    final value = raw?.toString().trim().toLowerCase() ?? '';
    if (const <String>{
      'user',
      'human',
      'you',
      'me',
      '使用者',
      '用戶',
      '用户',
    }.contains(value)) {
      return 'user';
    }
    if (const <String>{
      'assistant',
      'ai',
      'bot',
      'model',
      'grok',
      'character',
      '角色',
    }.contains(value)) {
      return 'assistant';
    }
    return null;
  }

  static String _textOf(Map<String, dynamic> map) {
    for (final key in const <String>['text', 'content', 'message', 'body']) {
      final value = map[key];
      final text = _flattenText(value);
      if (text.trim().isNotEmpty) return text;
    }
    return '';
  }

  static String _flattenText(Object? value) {
    if (value is String) return value;
    if (value is List) {
      return value
          .map(_flattenText)
          .where((part) => part.trim().isNotEmpty)
          .join('\n');
    }
    if (value is Map) {
      final map = _stringMap(value);
      for (final key in const <String>['text', 'parts', 'content', 'value']) {
        if (map.containsKey(key)) {
          final text = _flattenText(map[key]);
          if (text.trim().isNotEmpty) return text;
        }
      }
    }
    return '';
  }

  static ExternalImportPreview _parseMarkdown(String text) {
    final heading = RegExp(
      r'^\s{0,3}#{1,6}\s*(user|human|assistant|ai|用戶|用户|使用者|角色)\s*[:：]?\s*$',
      caseSensitive: false,
      multiLine: true,
    );
    final matches = heading.allMatches(text).toList(growable: false);
    if (matches.isEmpty) {
      return ExternalImportPreview(
        source: ExternalChatSource.markdown,
        conversations: const <ExternalImportConversation>[],
        warnings: const <String>[
          'No reliable speaker headings were found. This file is shown only as a reference document.',
        ],
        referenceDocument: text,
      );
    }
    final messages = <ExternalImportMessage>[];
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final end = index + 1 < matches.length
          ? matches[index + 1].start
          : text.length;
      final body = text.substring(match.end, end).trim();
      if (body.isEmpty) continue;
      final label = match.group(1)!.toLowerCase();
      final isUser = const <String>{
        'user',
        'human',
        '用戶',
        '用户',
        '使用者',
      }.contains(label);
      messages.add(ExternalImportMessage(isUser: isUser, text: body));
    }
    final digest = sha256
        .convert(utf8.encode(text))
        .toString()
        .substring(0, 16);
    return ExternalImportPreview(
      source: ExternalChatSource.markdown,
      conversations: <ExternalImportConversation>[
        ExternalImportConversation(
          sourceId: 'markdown-$digest',
          title: 'Imported conversation',
          messages: List<ExternalImportMessage>.unmodifiable(messages),
        ),
      ],
    );
  }

  static String _sourceId(Map<String, dynamic> item, int index) =>
      (item['id'] ??
              item['uuid'] ??
              item['conversation_id'] ??
              'conversation-$index')
          .toString();

  static String _titleOf(Map<String, dynamic> item, int index) {
    final title = (item['title'] ?? item['name'] ?? item['summary'])
        ?.toString()
        .trim();
    return title == null || title.isEmpty ? 'Conversation ${index + 1}' : title;
  }

  static DateTime _timestampOf(Object? raw) =>
      _dateTimeOf(
        raw is Map
            ? (_stringMap(raw)['create_time'] ?? _stringMap(raw)['created_at'])
            : raw,
      ) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  static DateTime? _dateTimeOf(Object? raw) {
    if (raw is num) {
      final milliseconds = raw.abs() < 100000000000
          ? (raw * 1000).round()
          : raw.round();
      return DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
        isUtc: true,
      ).toLocal();
    }
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return null;
    final numeric = num.tryParse(value);
    if (numeric != null) return _dateTimeOf(numeric);
    return DateTime.tryParse(value)?.toLocal();
  }

  static String _stableConversationId({
    required ExternalChatSource source,
    required ExternalImportConversation sourceConversation,
    required String characterId,
    required ContextMode contextMode,
    required String continuityId,
  }) {
    final seed = <String>[
      source.name,
      sourceConversation.sourceId,
      characterId,
      contextMode.storageValue,
      continuityId,
    ].join('\u001f');
    final digest = sha256.convert(utf8.encode(seed)).toString();
    return 'external-${digest.substring(0, 32)}';
  }

  /// External text must never be interpreted as Holt's hidden continuation
  /// protocol. A word joiner is invisible in the rendered transcript but
  /// prevents a user message from becoming an internal action marker.
  static String _safeImportedText(String text, {required bool isUser}) {
    if (isUser &&
        text.trimLeft().startsWith(Message.rpChapterContinuationPrefix)) {
      return '\u2060$text';
    }
    return text;
  }

  static Map<String, dynamic> _stringMap(Map raw) =>
      raw.map<String, dynamic>((key, value) => MapEntry(key.toString(), value));
}
