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
  static const int _maxLineagesPerConversation = 4;
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
      final historyRoot = sourceMessages.isEmpty
          ? 'empty'
          : _messageHash(sourceMessages.first);
      final baseScope = _baseScope(
        providerRoute: providerRoute,
        model: model,
        cacheChannel: cacheChannel,
      );
      final scope = _scope(
        providerRoute: providerRoute,
        model: model,
        cacheChannel: cacheChannel,
        historyRoot: historyRoot,
      );
      final retiredLineage = _retireOldLineages(
        entries,
        baseScope: baseScope,
        activeScope: scope,
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
      var changed = retiredLineage;
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
        await prefs.setString(
          _storageKey,
          jsonEncode(entries.map((entry) => entry.toJson()).toList()),
        );
      }

      return GrokPreparedHistory(
        messages: prepared,
        currentTurnAnchor: latestUserAnchor,
        ledgerScope: scope,
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
    String lineageScope = '',
  }) {
    if (turnAnchor.isEmpty || payload.isEmpty) return Future<void>.value();
    return _serialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final entries = _readEntries(prefs);
      final baseScope = _baseScope(
        providerRoute: providerRoute,
        model: model,
        cacheChannel: cacheChannel,
      );
      final matchingRuntime =
          entries
              .where(
                (entry) =>
                    entry.scope.startsWith('$baseScope\u0000') &&
                    entry.kind == 'runtime' &&
                    entry.anchor == turnAnchor,
              )
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final scope = lineageScope.trim().isNotEmpty
          ? lineageScope
          : (matchingRuntime.isNotEmpty
                ? matchingRuntime.first.scope
                : '$baseScope\u0000legacy');
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
    final images = ApiMessageMedia.imageDataUrls(source);
    if (role == 'user' && images.isNotEmpty) {
      return <String, dynamic>{
        'role': role,
        'content': <Map<String, dynamic>>[
          for (final image in images)
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, dynamic>{'url': image},
            },
          <String, dynamic>{
            'type': 'text',
            'text': content.isEmpty ? '（用戶發送了${images.length}張圖片）' : content,
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

  static String _baseScope({
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

  static String _scope({
    required String providerRoute,
    required String model,
    required String cacheChannel,
    required String historyRoot,
  }) {
    final base = _baseScope(
      providerRoute: providerRoute,
      model: model,
      cacheChannel: cacheChannel,
    );
    return '$base\u0000$historyRoot';
  }

  static void _appendCanonical(
    StringBuffer target,
    Map<String, String> message,
  ) {
    target.write(
      jsonEncode(<String>[
        message['role'] ?? 'user',
        message['content'] ?? '',
        _hash(message['image_data_urls'] ?? message['image_data_url'] ?? ''),
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

  /// A changed first retained message is an explicit cache checkpoint: the
  /// old immutable prefix must never be spliced into the new history. Keep the
  /// active lineage append-only, and retire only whole older lineages here.
  static bool _retireOldLineages(
    List<_LedgerEntry> entries, {
    required String baseScope,
    required String activeScope,
  }) {
    final prefix = '$baseScope\u0000';
    final lineages = <String, String>{};
    for (final entry in entries) {
      if (!entry.scope.startsWith(prefix)) continue;
      final previous = lineages[entry.scope];
      if (previous == null || entry.createdAt.compareTo(previous) > 0) {
        lineages[entry.scope] = entry.createdAt;
      }
    }
    if (lineages.containsKey(activeScope) ||
        lineages.length < _maxLineagesPerConversation) {
      return false;
    }
    final retired =
        lineages.entries.where((entry) => entry.key != activeScope).toList()
          ..sort((a, b) => a.value.compareTo(b.value));
    final removeCount = lineages.length - _maxLineagesPerConversation + 1;
    final removedScopes = retired
        .take(removeCount.clamp(0, retired.length))
        .map((entry) => entry.key)
        .toSet();
    if (removedScopes.isEmpty) return false;
    entries.removeWhere((entry) => removedScopes.contains(entry.scope));
    return true;
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
  final String ledgerScope;
  final String affinityId;
  final int runtimeEventCount;
  final int reasoningPayloadCount;
  final bool reusedCurrentRuntime;

  const GrokPreparedHistory({
    required this.messages,
    required this.currentTurnAnchor,
    required this.ledgerScope,
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
