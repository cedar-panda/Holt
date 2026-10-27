import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../memory/database.dart';
import '../models/message.dart';
import 'locale_strings.dart';

/// Extends only the request the user has already sent. No background resend,
/// keep-alive ping, or extra model call is scheduled here.
class IosReplyBackgroundTask {
  IosReplyBackgroundTask._(this.source, this._file, this._onExpire);

  static const channel = MethodChannel('holt/reply_background');
  static final Map<String, IosReplyBackgroundTask> _active = {};
  static bool _handlerInstalled = false;
  static ValueChanged<String>? _onOpenConversation;

  final Message source;
  final File _file;
  final VoidCallback _onExpire;
  final String token = '${DateTime.now().microsecondsSinceEpoch}';
  AppLifecycleListener? _lifecycle;
  String _text = '';
  Future<void> _writes = Future<void>.value();
  DateTime? _lastSave;
  bool _closed = false;
  bool _discard = false;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static void installMethodHandler({ValueChanged<String>? onOpenConversation}) {
    if (onOpenConversation != null) {
      _onOpenConversation = onOpenConversation;
    }
    if (_handlerInstalled) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openConversation') {
        final conversationId = call.arguments?.toString().trim() ?? '';
        if (conversationId.isNotEmpty) {
          _onOpenConversation?.call(conversationId);
        }
        return;
      }
      if (call.method != 'expired') return;
      final token = call.arguments as String?;
      final task = _active.values.where((task) => task.token == token);
      if (task.isEmpty) return;
      final active = task.first;
      // Cancel network first; retain the received text without running tools.
      active._onExpire();
      await active.flush();
      await active._native('end', {'success': false});
    });
    _handlerInstalled = true;
  }

  static Future<bool> requestNotificationPermission() async {
    if (!supported) return false;
    installMethodHandler();
    try {
      return await channel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> markNotificationHandlerReady() async {
    if (!supported) return;
    installMethodHandler();
    try {
      await channel.invokeMethod<void>('notificationHandlerReady');
    } on PlatformException {
      // An old native shell simply cannot forward notification taps yet.
    } on MissingPluginException {
      // Unit tests and older installs remain usable.
    }
  }

  static Future<void> clearConversationNotifications(
    String conversationId,
  ) async {
    if (!supported) return;
    installMethodHandler();
    try {
      await channel.invokeMethod<void>('clearConversationNotifications', {
        'conversationId': conversationId,
      });
    } on PlatformException {
      // Delivered notifications may remain, but chat navigation still works.
    } on MissingPluginException {
      // Old native shells remain compatible.
    }
  }

  static Future<File> _checkpointFile(String conversationId) async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}/reply_checkpoints');
    await directory.create(recursive: true);
    final name = sha256.convert(utf8.encode(conversationId));
    return File('${directory.path}/$name.json');
  }

  static Future<IosReplyBackgroundTask?> begin({
    required Message source,
    required VoidCallback onExpire,
    File? checkpointFile,
  }) async {
    if (!supported || source.id == null) return null;
    installMethodHandler();
    final previous = _active[source.conversationId];
    if (previous != null) await previous.finish(discard: false);
    File file;
    try {
      file = checkpointFile ?? await _checkpointFile(source.conversationId);
    } on FileSystemException {
      return null;
    } on PlatformException {
      return null;
    }
    final task = IosReplyBackgroundTask._(source, file, onExpire);
    _active[source.conversationId] = task;
    task._lifecycle = AppLifecycleListener(
      onPause: () => unawaited(task.flush()),
    );
    await task._native('begin', {
      'title': L.pick(en: 'Holt reply', zhTW: 'Holt 回覆', zhCN: 'Holt 回复'),
      'subtitle': L.pick(
        en: 'Receiving your reply…',
        zhTW: '正在接收回覆……',
        zhCN: '正在接收回复……',
      ),
    });
    return task;
  }

  Future<void> _native(String method, Map<String, Object> arguments) async {
    try {
      await channel.invokeMethod<Object?>(method, {
        'token': token,
        ...arguments,
      });
    } on PlatformException {
      // An unavailable scheduler must never prevent normal foreground chat.
    } on MissingPluginException {
      // Old native shell and unit-test hosts still support foreground chat.
    }
  }

  Future<void> record(String visibleText) async {
    if (_closed) return;
    _text = visibleText;
    final now = DateTime.now();
    if (_lastSave != null &&
        now.difference(_lastSave!) < const Duration(seconds: 2)) {
      return;
    }
    _lastSave = now;
    await flush();
    await _native('progress', {'characters': _text.runes.length});
  }

  Future<void> flush() {
    final text = _text;
    if (_closed || _discard || text.isEmpty) return _writes;
    _writes = _writes
        .catchError((Object _) {})
        .then((_) async {
          if (_discard) return;
          final temporary = File('${_file.path}.tmp');
          await temporary.writeAsString(
            jsonEncode({
              'source_id': source.id,
              'source_revision': source.revision,
              'conversation_id': source.conversationId,
              'character_id': source.characterId,
              'text': text,
              'created_at': DateTime.now().toIso8601String(),
            }),
            flush: true,
          );
          await temporary.rename(_file.path);
        })
        .catchError((Object _) {
          // Checkpoint I/O failure must not abort a paid streaming request.
          debugPrint('Unable to save reply checkpoint.');
        });
    return _writes;
  }

  /// Only call discard after the normal reply or incomplete reply is in SQLite.
  Future<void> finish({
    required bool discard,
    bool completed = false,
    String? notificationTitle,
    String? notificationBody,
    String? notificationPlaceholder,
    String? notificationCharacterId,
  }) async {
    if (_closed) return;
    if (!discard) await flush();
    _discard = discard;
    _closed = true;
    _lifecycle?.dispose();
    await _writes.catchError((Object _) {});
    if (discard) {
      try {
        if (await _file.exists()) await _file.delete();
      } on FileSystemException {
        // Recovery checks SQLite first, so an obsolete journal is harmless.
      }
    }
    if (identical(_active[source.conversationId], this)) {
      _active.remove(source.conversationId);
    }
    final arguments = <String, Object>{
      'success': completed,
      'conversationId': source.conversationId,
    };
    if (notificationTitle != null) arguments['title'] = notificationTitle;
    if (notificationBody != null) arguments['body'] = notificationBody;
    if (notificationPlaceholder != null) {
      arguments['placeholder'] = notificationPlaceholder;
    }
    if (notificationCharacterId != null) {
      arguments['characterId'] = notificationCharacterId;
    }
    await _native('end', arguments);
  }

  /// Recover only the last unanswered, unchanged user turn. An edited source,
  /// deleted window, or a reply already saved cannot resurrect a ghost reply.
  static Future<void> recover(
    String conversationId, {
    File? checkpointFile,
  }) async {
    if (!supported || _active.containsKey(conversationId)) return;
    final file = checkpointFile ?? await _checkpointFile(conversationId);
    if (!await file.exists()) return;
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      data = decoded;
    } on FormatException {
      return;
    } on FileSystemException {
      return;
    }
    if (data['source_id'] is! int ||
        data['source_revision'] is! int ||
        data['character_id'] is! String ||
        data['text'] is! String ||
        data['created_at'] is! String) {
      return;
    }
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      final source = await txn.query(
        'messages',
        where:
            'id = ? AND conversation_id = ? AND character_id = ? AND is_user = 1 AND revision = ?',
        whereArgs: [
          data['source_id'],
          conversationId,
          data['character_id'],
          data['source_revision'],
        ],
      );
      if (data['conversation_id'] != conversationId || source.isEmpty) return;
      final later = await txn.query(
        'messages',
        columns: ['id'],
        where: 'conversation_id = ? AND id > ?',
        whereArgs: [conversationId, data['source_id']],
        limit: 1,
      );
      final text = (data['text'] as String? ?? '').trim();
      if (later.isNotEmpty || text.isEmpty) return;
      final message = Message(
        conversationId: conversationId,
        characterId: data['character_id'] as String,
        text: text,
        isUser: false,
        status: Message.statusIncomplete,
        createdAt: DateTime.tryParse(data['created_at'] as String? ?? ''),
      );
      final row = message.toMap()..remove('id');
      row['reply_to_message_id'] = data['source_id'];
      await txn.insert('messages', row);
    });
    await file.delete();
  }
}
