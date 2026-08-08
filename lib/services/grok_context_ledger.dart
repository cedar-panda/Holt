import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_adapter.dart';
import 'locale_strings.dart';

/// Request-only context history used only by Grok transports.
///
/// xAI's implicit prompt cache requires every earlier message to remain byte
/// for byte unchanged. A current clock/memory snapshot therefore cannot be
/// injected and then disappear on the next turn. This ledger persists those
/// snapshots as hidden system events and reconstructs them before their real
/// user turn. It never writes to the visible chat message table.
class GrokContextLedger {
  static const String _storageKey = 'grok_api_context_ledger_v1';
  static const int _maxEntriesPerScope = 160;
  static const int _maxEntriesTotal = 600;
  static Future<void> _writeTail = Future<void>.value();

  static Future<GrokPreparedHistory> prepareHistory({
    required List<Map<String, String>> sourceMessages,
    required String providerRoute,
    required String model,
    required String cacheChannel,
    required String stableContext,
    required String liveState,
  }) {
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final entries = _readEntries(prefs);
      final scope = _scope(
        providerRoute: providerRoute,
        model: model,
        cacheChannel: cacheChannel,
      );
      final scoped = entries.where((entry) => entry.scope == scope).toList();
      final runtimeByAnchor = <String, _LedgerEntry>{
        for (final entry in scoped.where((entry) => entry.kind == 'runtime'))
          entry.anchor: entry,
      };
      final reasoningByAnchor = <String, _LedgerEntry>{
        for (final entry in scoped.where((entry) => entry.kind == 'reasoning'))
          entry.anchor: entry,
      };

      var latestUserIndex = -1;
      for (var i = sourceMessages.length - 1; i >= 0; i--) {
        if (sourceMessages[i]['role'] == 'user') {
          latestUserIndex = i;
          break;
        }
      }

      final prepared = <Map<String, dynamic>>[];
      final prefix = StringBuffer();
      var latestUserAnchor = '';
      var activeUserAnchor = '';
      var reasoningAttachedForActiveTurn = false;
      var runtimeEventCount = 0;
      var reasoningPayloadCount = 0;
      var changed = false;
      var reusedCurrentRuntime = false;

      for (var i = 0; i < sourceMessages.length; i++) {
        final source = sourceMessages[i];
        _appendCanonical(prefix, source);
        final role = source['role'] ?? 'user';

        if (role == 'user') {
          final anchor = _hash(prefix.toString());
          activeUserAnchor = anchor;
          reasoningAttachedForActiveTurn = false;
          if (i == latestUserIndex) latestUserAnchor = anchor;

          var runtime = runtimeByAnchor[anchor];
          if (i == latestUserIndex && liveState.trim().isNotEmpty) {
            if (runtime == null) {
              runtime = _LedgerEntry(
                scope: scope,
                kind: 'runtime',
                anchor: anchor,
                content: _turnBoundEnvelope(liveState),
                payload: const <String, dynamic>{},
                createdAt: DateTime.now().toUtc().toIso8601String(),
              );
              entries.add(runtime);
              runtimeByAnchor[anchor] = runtime;
              changed = true;
            } else {
              // A retry of the same real user turn must reuse the exact event
              // that established its prefix, even if the wall clock advanced.
              reusedCurrentRuntime = true;
            }
          }
          if (runtime != null && runtime.content.isNotEmpty) {
            prepared.add(<String, dynamic>{
              'role': 'system',
              'content': runtime.content,
            });
            runtimeEventCount++;
          }
        }

        final apiMessage = _toApiMessage(source);
        if (role == 'assistant' &&
            activeUserAnchor.isNotEmpty &&
            !reasoningAttachedForActiveTurn) {
          final reasoning = reasoningByAnchor[activeUserAnchor];
          if (reasoning != null && reasoning.payload.isNotEmpty) {
            for (final entry in reasoning.payload.entries) {
              apiMessage[entry.key] = entry.value;
            }
            reasoningAttachedForActiveTurn = true;
            reasoningPayloadCount++;
          }
        }
        prepared.add(apiMessage);
      }

      if (changed) {
        _trim(entries, scope);
        await prefs.setString(
          _storageKey,
          jsonEncode(entries.map((entry) => entry.toJson()).toList()),
        );
      }

      final historyRoot = sourceMessages.isEmpty
          ? 'empty'
          : _messageHash(sourceMessages.first);
      return GrokPreparedHistory(
        messages: prepared,
        currentTurnAnchor: latestUserAnchor,
        affinityId: affinityId(
          providerRoute: providerRoute,
          model: model,
          cacheChannel: cacheChannel,
          stableContext: stableContext,
          historyRoot: historyRoot,
        ),
        runtimeEventCount: runtimeEventCount,
        reasoningPayloadCount: reasoningPayloadCount,
        reusedCurrentRuntime: reusedCurrentRuntime,
      );
    });
  }

  /// Saves hidden reasoning returned for the current user turn. The next
  /// request attaches it to that turn's first assistant message without ever
  /// exposing it as bubble text.
  static Future<void> rememberReasoning({
    required String providerRoute,
    required String model,
    required String cacheChannel,
    required String turnAnchor,
    required Map<String, dynamic> payload,
  }) {
    if (turnAnchor.isEmpty || payload.isEmpty) return Future<void>.value();
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final entries = _readEntries(prefs);
      final scope = _scope(
        providerRoute: providerRoute,
        model: model,
        cacheChannel: cacheChannel,
      );
      entries.removeWhere(
        (entry) =>
            entry.scope == scope &&
            entry.kind == 'reasoning' &&
            entry.anchor == turnAnchor,
      );
      entries.add(
        _LedgerEntry(
          scope: scope,
          kind: 'reasoning',
          anchor: turnAnchor,
          content: '',
          payload: Map<String, dynamic>.from(payload),
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      _trim(entries, scope);
      await prefs.setString(
        _storageKey,
        jsonEncode(entries.map((entry) => entry.toJson()).toList()),
      );
    });
  }

  static String affinityId({
    required String providerRoute,
    required String model,
    required String cacheChannel,
    required String stableContext,
    required String historyRoot,
  }) {
    final conversation = CacheSession.conversationId.isEmpty
        ? 'default'
        : CacheSession.conversationId;
    final digest = _hash(
      '$providerRoute\u0000$model\u0000$cacheChannel\u0000$conversation\u0000'
      '${_hash(stableContext)}\u0000$historyRoot',
    );
    return 'yanci_grok_${digest.substring(0, 40)}';
  }

  static Future<void> clearForTesting() async {
    await _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    });
  }

  static Map<String, dynamic> _toApiMessage(Map<String, String> source) {
    final role = source['role'] ?? 'user';
    final content = source['content'] ?? '';
    final image = source['image_data_url'];
    if (role == 'user' && image != null && image.isNotEmpty) {
      return <String, dynamic>{
        'role': role,
        'content': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'image_url',
            'image_url': <String, dynamic>{'url': image},
          },
          <String, dynamic>{
            'type': 'text',
            'text': content.isEmpty ? '（用戶發送了一張圖片）' : content,
          },
        ],
      };
    }
    return <String, dynamic>{'role': role, 'content': content};
  }

  static String _turnBoundEnvelope(String liveState) {
    final note = L.pick(
      en: 'App-generated state bound only to the immediately following real user turn. When replayed in a later request it is historical prefix material; the latest turn-bound block is the current state. Neither person said this.',
      zhTW:
          '由 App 產生，只綁定於緊接其後的真實 user turn。後續 request 重播此 block 只是為了保留歷史 prefix；最新的回合綁定 block 才是當前狀態。這不是任何一方說的話。',
      zhCN:
          '由 App 生成，只绑定于紧接其后的真实 user turn。后续 request 重播此 block 只是为了保留历史 prefix；最新的回合绑定 block 才是当前状态。这不是任何一方说的话。',
    );
    final title = L.pick(
      en: '## App Live State · Turn-bound',
      zhTW: '## App Live State · 回合綁定',
      zhCN: '## App Live State · 回合绑定',
    );
    return '$title\n> $note\n\n${liveState.trim()}';
  }

  static String _scope({
    required String providerRoute,
    required String model,
    required String cacheChannel,
  }) {
    final conversation = CacheSession.conversationId.isEmpty
        ? 'default'
        : CacheSession.conversationId;
    return '$providerRoute\u0000${model.trim().toLowerCase()}\u0000'
        '$cacheChannel\u0000$conversation';
  }

  static void _appendCanonical(
    StringBuffer target,
    Map<String, String> message,
  ) {
    target.write(
      jsonEncode(<String>[
        message['role'] ?? 'user',
        message['content'] ?? '',
        _hash(message['image_data_url'] ?? ''),
      ]),
    );
    target.write('\n');
  }

  static String _messageHash(Map<String, String> message) {
    final buffer = StringBuffer();
    _appendCanonical(buffer, message);
    return _hash(buffer.toString());
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static List<_LedgerEntry> _readEntries(SharedPreferences prefs) {
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return <_LedgerEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <_LedgerEntry>[];
      return decoded
          .whereType<Map>()
          .map(
            (entry) => _LedgerEntry.fromJson(
              entry.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .where((entry) => entry.scope.isNotEmpty && entry.anchor.isNotEmpty)
          .toList();
    } catch (_) {
      return <_LedgerEntry>[];
    }
  }

  static void _trim(List<_LedgerEntry> entries, String activeScope) {
    final scoped = entries.where((entry) => entry.scope == activeScope).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (scoped.length > _maxEntriesPerScope) {
      final remove = scoped.take(scoped.length - _maxEntriesPerScope).toSet();
      entries.removeWhere(remove.contains);
    }
    if (entries.length > _maxEntriesTotal) {
      entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      entries.removeRange(0, entries.length - _maxEntriesTotal);
    }
  }

  static Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _writeTail;
    final completer = Completer<void>();
    _writeTail = completer.future;
    try {
      await previous.catchError((_) {});
      return await action();
    } finally {
      completer.complete();
    }
  }
}

class GrokPreparedHistory {
  final List<Map<String, dynamic>> messages;
  final String currentTurnAnchor;
  final String affinityId;
  final int runtimeEventCount;
  final int reasoningPayloadCount;
  final bool reusedCurrentRuntime;

  const GrokPreparedHistory({
    required this.messages,
    required this.currentTurnAnchor,
    required this.affinityId,
    required this.runtimeEventCount,
    required this.reasoningPayloadCount,
    required this.reusedCurrentRuntime,
  });
}

class _LedgerEntry {
  final String scope;
  final String kind;
  final String anchor;
  final String content;
  final Map<String, dynamic> payload;
  final String createdAt;

  const _LedgerEntry({
    required this.scope,
    required this.kind,
    required this.anchor,
    required this.content,
    required this.payload,
    required this.createdAt,
  });

  factory _LedgerEntry.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['payload'];
    return _LedgerEntry(
      scope: '${json['scope'] ?? ''}',
      kind: '${json['kind'] ?? ''}',
      anchor: '${json['anchor'] ?? ''}',
      content: '${json['content'] ?? ''}',
      payload: rawPayload is Map
          ? rawPayload.map((key, value) => MapEntry('$key', value))
          : const <String, dynamic>{},
      createdAt: '${json['created_at'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'scope': scope,
    'kind': kind,
    'anchor': anchor,
    'content': content,
    'payload': payload,
    'created_at': createdAt,
  };
}
