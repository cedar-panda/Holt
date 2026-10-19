import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../memory/database.dart';
import '../models/message.dart';
import 'locale_strings.dart';
import 'token_estimator.dart';

/// Stores mutable RP facts for one storyline without modifying the reusable
/// user persona or character card.
abstract final class RpStoryStateService {
  static const Uuid _uuid = Uuid();
  static const int extractionLimit = 12;

  static const Set<String> _types = <String>{
    'scene',
    'promise',
    'body',
    'identity',
    'knowledge',
    'plot',
    'item',
  };
  static const Set<String> _layers = <String>{
    'main',
    'memory',
    'dream',
    'hypothetical',
    'au',
    'ooc',
  };

  static String _storageLayer(String raw) => switch (raw) {
    'mainline' => 'main',
    'flashback' => 'memory',
    'side_story' => 'au',
    'dream' || 'hypothetical' => raw,
    _ => 'main',
  };
  static const Map<String, Set<String>> _statuses = <String, Set<String>>{
    'scene': <String>{''},
    'promise': <String>{'pending', 'fulfilled', 'broken', 'cancelled'},
    'body': <String>{'permanent', 'recovering', 'healed'},
    'identity': <String>{'active', 'suspended', 'revoked', 'unknown'},
    'knowledge': <String>{
      'unaware',
      'suspicious',
      'heard',
      'investigating',
      'believed',
      'confirmed',
    },
    'plot': <String>{'active', 'resolved', 'stalled'},
    'item': <String>{'held', 'lost', 'destroyed', 'transferred', 'unknown'},
  };

  static List<String> validStatuses(String stateType) =>
      (_statuses[stateType] ?? const <String>{}).toList(growable: false);

  static String _scope(String value) =>
      value.trim().isEmpty ? 'main' : value.trim();

  static String _text(Map<String, Object?> row, String key) =>
      row[key]?.toString().trim() ?? '';

  static List<int> _sourceIds(Object? raw) {
    if (raw is! List) return const <int>[];
    return raw
        .map(
          (value) => switch (value) {
            num number => number.toInt(),
            String text => int.tryParse(text.trim()),
            _ => null,
          },
        )
        .whereType<int>()
        .where((id) => id > 0)
        .toSet()
        .toList(growable: false);
  }

  static List<String> _replacedKeys(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .map((value) => value?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  static int _latestSourceId(Object? raw) {
    final ids = raw is String
        ? (() {
            try {
              return _sourceIds(jsonDecode(raw));
            } catch (_) {
              return const <int>[];
            }
          })()
        : _sourceIds(raw);
    return ids.fold<int>(0, (latest, id) => id > latest ? id : latest);
  }

  static String _slug(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\p{L}\p{N}]+', unicode: true), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  static bool _entityKey(String value) => RegExp(r'^P-\d{4,}$').hasMatch(value);

  static Future<bool> _entitiesExist(
    DatabaseExecutor db,
    String characterId,
    String continuityId,
    Iterable<String> keys,
  ) async {
    final required = keys.where((key) => key.isNotEmpty).toSet();
    if (required.isEmpty) return true;
    if (required.any((key) => !_entityKey(key))) return false;
    final placeholders = List.filled(required.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT entity_key FROM rp_story_characters '
      'WHERE character_id = ? AND continuity_id = ? '
      'AND entity_key IN ($placeholders)',
      <Object?>[characterId, continuityId, ...required],
    );
    return rows.map((row) => row['entity_key']?.toString()).toSet().length ==
        required.length;
  }

  static String? _canonicalKey(
    String type,
    String rawKey,
    String subject,
    String object,
  ) {
    if (type == 'scene') return rawKey == 'scene.current' ? rawKey : null;
    final rawParts = rawKey
        .split('.')
        .where((part) => part.isNotEmpty)
        .toList();
    if (rawParts.isEmpty || rawParts.first != type) return null;
    var semanticParts = rawParts.skip(1).toList(growable: false);
    if (type == 'knowledge' &&
        semanticParts.length >= 3 &&
        semanticParts[0] == subject &&
        semanticParts[1] == object) {
      semanticParts = semanticParts.skip(2).toList(growable: false);
    } else if (type != 'plot' &&
        semanticParts.length >= 2 &&
        semanticParts.first == subject) {
      semanticParts = semanticParts.skip(1).toList(growable: false);
    }
    final tail = _slug(semanticParts.join('_'));
    if (tail.isEmpty) return null;
    return switch (type) {
      'knowledge' when subject.isNotEmpty && object.isNotEmpty =>
        'knowledge.$subject.$object.$tail',
      'promise' ||
      'body' ||
      'identity' ||
      'item' when subject.isNotEmpty => '$type.$subject.$tail',
      'plot' => 'plot.$tail',
      _ => null,
    };
  }

  static bool _supportedBySource(
    Map<String, Object?> candidate,
    Map<int, Message> sources,
  ) {
    final ids = _sourceIds(candidate['source_message_ids']);
    final evidence = _text(candidate, 'evidence');
    if (ids.isEmpty || evidence.isEmpty) return false;
    return ids.every(sources.containsKey) &&
        ids.any((id) => sources[id]!.text.contains(evidence));
  }

  /// Upserts at most twelve state changes. Missing `scene.current` means the
  /// program keeps the previous scene unchanged; callers never need to copy it.
  /// Non-main narrative layers remain stored for provenance but are excluded
  /// from normal scene recall.
  static Future<int> storeExtraction({
    required String characterId,
    required String continuityId,
    required String sourceConversationId,
    required List<Map<String, Object?>> states,
    required List<Message> sourceMessages,
    int? sourceSummaryId,
  }) async {
    if (states.isEmpty) return 0;
    final db = await DatabaseHelper.database;
    final scope = _scope(continuityId);
    final sources = <int, Message>{
      for (final message in sourceMessages)
        if (message.id != null) message.id!: message,
    };
    final now = DateTime.now().toIso8601String();
    var stored = 0;
    await db.transaction((txn) async {
      if (sourceSummaryId != null) {
        final summary = await txn.query(
          'context_summaries',
          columns: const <String>['id'],
          where: "id = ? AND revision_status = 'valid'",
          whereArgs: <Object?>[sourceSummaryId],
          limit: 1,
        );
        if (summary.isEmpty) return;
      }
      for (final candidate in states.take(extractionLimit)) {
        if (!_supportedBySource(candidate, sources)) continue;
        final type = _text(candidate, 'state_type');
        if (!_types.contains(type)) continue;
        final layer = _storageLayer(_text(candidate, 'narrative_layer'));
        final narrativeLayer = _layers.contains(layer) ? layer : 'main';
        final subject = _text(candidate, 'subject_entity_key');
        final object = _text(candidate, 'object_entity_key');
        if (!await _entitiesExist(txn, characterId, scope, <String>[
          subject,
          object,
        ])) {
          continue;
        }
        final key = _canonicalKey(
          type,
          _text(candidate, 'state_key'),
          subject,
          object,
        );
        if (key == null) continue;
        final value = _text(candidate, 'value');
        if (value.isEmpty) continue;
        final rawStatus = _text(candidate, 'status');
        final status = _statuses[type]!.contains(rawStatus)
            ? rawStatus
            : (type == 'scene' ? '' : null);
        if (status == null) continue;
        final replaces = _replacedKeys(
          candidate['replaces_state_keys'],
        ).where((oldKey) => oldKey != key).take(3).toList(growable: false);
        var targetKey = key;
        if (replaces.isNotEmpty) {
          final newKeyExists = (await txn.query(
            'rp_story_states',
            columns: const <String>['id'],
            where: 'character_id = ? AND continuity_id = ? AND state_key = ?',
            whereArgs: <Object?>[characterId, scope, key],
            limit: 1,
          )).isNotEmpty;
          if (!newKeyExists) {
            final olds = await txn.query(
              'rp_story_states',
              where:
                  'character_id = ? AND continuity_id = ? AND state_key IN '
                  '(${List.filled(replaces.length, '?').join(',')}) '
                  'AND state_type = ? AND subject_entity_key = ? '
                  'AND object_entity_key = ? AND user_edited = 0',
              whereArgs: <Object?>[
                characterId,
                scope,
                ...replaces,
                type,
                subject,
                object,
              ],
            );
            if (olds.isNotEmpty) {
              targetKey = olds.first['state_key']! as String;
              for (final duplicate in olds.skip(1)) {
                await txn.delete(
                  'rp_story_states',
                  where: 'id = ?',
                  whereArgs: <Object?>[duplicate['id']],
                );
              }
            }
          }
        }
        final existing = await txn.query(
          'rp_story_states',
          where: 'character_id = ? AND continuity_id = ? AND state_key = ?',
          whereArgs: <Object?>[characterId, scope, targetKey],
          limit: 1,
        );
        if (existing.isNotEmpty && existing.first['user_edited'] == 1) {
          continue;
        }
        final incomingSequence = _latestSourceId(
          candidate['source_message_ids'],
        );
        if (existing.isNotEmpty &&
            _latestSourceId(existing.first['source_message_ids']) >
                incomingSequence) {
          continue;
        }
        final values = <String, Object?>{
          'state_type': type,
          'subject_entity_key': subject,
          'object_entity_key': object,
          'narrative_layer': narrativeLayer,
          'value': value,
          'status': status,
          'story_time': _text(candidate, 'story_time'),
          'source_conversation_id': sourceConversationId,
          'source_message_ids': jsonEncode(
            _sourceIds(candidate['source_message_ids']),
          ),
          'source_summary_id': sourceSummaryId,
          'evidence': _text(candidate, 'evidence'),
          'updated_at': now,
        };
        if (existing.isEmpty) {
          await txn.insert('rp_story_states', <String, Object?>{
            'id': _uuid.v4(),
            'character_id': characterId,
            'continuity_id': scope,
            'state_key': targetKey,
            ...values,
            'created_at': now,
          });
        } else {
          await txn.update(
            'rp_story_states',
            values,
            where: 'id = ?',
            whereArgs: <Object?>[existing.first['id']],
          );
        }
        stored += 1;
      }
    });
    return stored;
  }

  static Future<List<Map<String, dynamic>>> listStates(
    String characterId, {
    String continuityId = 'main',
    bool includeNonMain = false,
  }) async {
    final db = await DatabaseHelper.database;
    return db.query(
      'rp_story_states',
      where: includeNonMain
          ? 'character_id = ? AND continuity_id = ?'
          : "character_id = ? AND continuity_id = ? AND narrative_layer = 'main'",
      whereArgs: <Object?>[characterId, _scope(continuityId)],
      orderBy:
          "CASE state_type WHEN 'scene' THEN 0 ELSE 1 END, updated_at DESC",
    );
  }

  /// Whether a state still belongs in the live handoff context. Terminal
  /// results remain in the dossier/timeline, but no longer compete with the
  /// facts the next reply must actively obey.
  static bool isActiveForRecall(Map<String, dynamic> row) {
    final type = row['state_type']?.toString() ?? '';
    final status = row['status']?.toString() ?? '';
    return switch (type) {
      'scene' => true,
      'promise' => status == 'pending',
      'body' => status == 'permanent' || status == 'recovering',
      'identity' =>
        status == 'active' || status == 'suspended' || status == 'unknown',
      'plot' => status == 'active' || status == 'stalled',
      // Knowledge and item rows describe the current known/possession state,
      // including terminal-looking values such as confirmed or destroyed.
      'knowledge' || 'item' => true,
      _ => false,
    };
  }

  /// Body and identity rows are mutable snapshots, not an event log. Older
  /// snapshots remain in the database for provenance, but only the newest
  /// active snapshot of each kind is useful to the reply model. Promise,
  /// knowledge, plot and item rows may describe independent live threads and
  /// therefore stay discrete.
  static List<Map<String, dynamic>> _compactCurrentSnapshots(
    Iterable<Map<String, dynamic>> rows,
    Set<String> appearingEntityKeys,
  ) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final type = row['state_type']?.toString() ?? '';
      final subject = row['subject_entity_key']?.toString().trim() ?? '';
      final stateKey = row['state_key']?.toString().trim() ?? '';
      final keyParts = stateKey.split('.');
      final owner = subject.isNotEmpty
          ? subject
          : (keyParts.length > 1 ? keyParts[1] : stateKey);
      final isMutableSnapshot = type == 'body' || type == 'identity';
      final isOffstagePerson =
          owner.isNotEmpty && !appearingEntityKeys.contains(owner);
      final object = row['object_entity_key']?.toString().trim() ?? '';
      // Knowledge is directional. Compacting only by the subject would let a
      // newer Jiang-An -> Xie entry accidentally hide Jiang-An -> somebody
      // else. Offstage knowledge is therefore newest-per-directed-pair.
      final recallOwner = type == 'knowledge' && object.isNotEmpty
          ? '$owner|$object'
          : owner;
      final dedupeKey = isOffstagePerson
          ? '$type|$recallOwner'
          : (isMutableSnapshot ? '$type|$stateKey' : null);
      if (dedupeKey != null && !seen.add(dedupeKey)) continue;
      result.add(row);
    }
    return result;
  }

  static String _stateTypeLabel(String type) => switch (type) {
    'scene' => L.pick(en: 'Scene', zhTW: '場景', zhCN: '场景'),
    'promise' => L.pick(en: 'Promise', zhTW: '約定', zhCN: '约定'),
    'body' => L.pick(en: 'Condition', zhTW: '身體', zhCN: '身体'),
    'identity' => L.pick(en: 'Identity', zhTW: '身分', zhCN: '身份'),
    'knowledge' => L.pick(en: 'Knowledge', zhTW: '知情', zhCN: '知情'),
    'plot' => L.pick(en: 'Open thread', zhTW: '未結線索', zhCN: '未结线索'),
    'item' => L.pick(en: 'Item', zhTW: '物品', zhCN: '物品'),
    _ => type,
  };

  static String _stateDetailLabel(String type, String status) {
    if (type == 'knowledge') {
      return switch (status) {
        'unaware' => L.pick(en: 'unaware', zhTW: '不知情', zhCN: '不知情'),
        'suspicious' => L.pick(en: 'suspects', zhTW: '懷疑', zhCN: '怀疑'),
        'heard' => L.pick(en: 'has heard', zhTW: '曾聽聞', zhCN: '曾听闻'),
        'investigating' => L.pick(
          en: 'investigating',
          zhTW: '查證中',
          zhCN: '查证中',
        ),
        'believed' => L.pick(en: 'believes', zhTW: '相信', zhCN: '相信'),
        'confirmed' => L.pick(en: 'confirmed', zhTW: '已確認', zhCN: '已确认'),
        _ => _stateTypeLabel(type),
      };
    }
    return _stateTypeLabel(type);
  }

  /// Request-only state context. It is appended to the existing RP character
  /// reference block, preserving the established injection position and cache
  /// boundary instead of creating a new system-prompt slot.
  static Future<String> recallPrompt(
    String characterId, {
    String continuityId = 'main',
    int tokenBudget = 1200,
    List<Message> recentMessages = const <Message>[],
  }) async {
    final db = await DatabaseHelper.database;
    final scope = _scope(continuityId);
    final latestReplyId = recentMessages
        .where((message) => !message.isUser && !message.isIncomplete)
        .fold<int>(
          0,
          (latest, message) =>
              (message.id ?? 0) > latest ? message.id! : latest,
        );
    final includeCorrectionKeys = _hasExplicitCorrectionIntent(recentMessages);
    var states = List<Map<String, dynamic>>.of(
      (await listStates(characterId, continuityId: scope)).where((state) {
        if (!isActiveForRecall(state)) return false;
        // A recorded scene is a checkpoint, not a per-turn location tracker.
        // Once newer reply text exists, omit the old scene snapshot rather
        // than presenting it as the present. Other durable facts remain.
        if (state['state_type'] == 'scene' &&
            state['user_edited'] != 1 &&
            latestReplyId > 0) {
          final recordedThrough = _latestSourceId(state['source_message_ids']);
          if (recordedThrough == 0 || latestReplyId > recordedThrough) {
            return false;
          }
        }
        return true;
      }),
      growable: true,
    );
    if (states.isEmpty) return '';
    final people = await db.query(
      'rp_story_characters',
      columns: const <String>['entity_key', 'name', 'aliases_json'],
      where: 'character_id = ? AND continuity_id = ?',
      whereArgs: <Object?>[characterId, scope],
    );
    final names = <String, String>{
      for (final person in people)
        person['entity_key']!.toString(): person['name']!.toString(),
    };
    final recentNarrative = recentMessages.reversed
        .where((message) => !message.isIncomplete)
        .map((message) => message.promptVisibleText.trim())
        .where((text) => text.isNotEmpty)
        .take(8)
        .join('\n')
        .toLowerCase();
    final appearingEntityKeys = <String>{};
    for (final person in people) {
      final terms =
          <String>[
                person['name']?.toString() ?? '',
                ..._decodeAliases(person['aliases_json']),
              ]
              .map((term) => term.trim().toLowerCase())
              .where((term) => term.length >= 2);
      if (recentNarrative.isNotEmpty && terms.any(recentNarrative.contains)) {
        appearingEntityKeys.add(person['entity_key']!.toString());
      }
    }
    // An explicit correction turn needs every machine key so a precise update
    // can be proposed. Ordinary generation keeps every live thread for people
    // in the current scene, but only the newest row per type for offstage cast.
    // Body and identity are mutable snapshots, so their older stages are
    // always suppressed even when that person is present.
    if (!includeCorrectionKeys) {
      states = _compactCurrentSnapshots(states, appearingEntityKeys);
    }
    int priority(Map<String, dynamic> row) => switch (row['state_type']) {
      'scene' => 0,
      'identity' || 'knowledge' => 1,
      'body' || 'promise' => 2,
      _ => 3,
    };
    states.sort((a, b) {
      final byPriority = priority(a).compareTo(priority(b));
      if (byPriority != 0) return byPriority;
      return (b['updated_at']?.toString() ?? '').compareTo(
        a['updated_at']?.toString() ?? '',
      );
    });
    final out = StringBuffer()
      ..writeln(
        L.pick(
          en: '【Story State】This is not a live scene. Use only to fill gaps in the latest effective narrative. Never let an old snapshot override newer text or replay a completed action. Claims, dreams and hypotheticals are not mainline facts.',
          zhTW: '【劇情現況】僅補最近有效正文未交代的資訊。舊快照不得覆蓋新進展，已完成行動不得重演；角色說法、夢境與假設不視為主線事實。',
          zhCN: '【剧情现况】仅补最近有效正文未交代的信息。旧快照不得覆盖新进展，已完成行动不得重演；角色说法、梦境与假设不视为主线事实。',
        ),
      );
    for (final state in states) {
      final subject = names[state['subject_entity_key']] ?? '';
      final object = names[state['object_entity_key']] ?? '';
      final participants = <String>[
        subject,
        object,
      ].where((value) => value.isNotEmpty).join(' → ');
      final stateKey = state['state_key']?.toString() ?? '';
      final corrected = (state['evidence']?.toString() ?? '').startsWith(
        '[model_user_correction]',
      );
      final type = state['state_type']?.toString() ?? '';
      final status = state['status']?.toString() ?? '';
      final owner = participants.isEmpty ? _stateTypeLabel(type) : participants;
      final detail = <String>[
        if (participants.isNotEmpty) _stateDetailLabel(type, status),
        if (corrected) L.pick(en: 'corrected', zhTW: '已修正', zhCN: '已修正'),
        if (includeCorrectionKeys && stateKey.isNotEmpty) 'state_key=$stateKey',
      ].join('｜');
      final label = detail.isEmpty ? owner : '$owner｜$detail';
      final line = '- $label：${state['value']}';
      final candidate = '${out.toString()}$line\n';
      if (TokenEstimator.estimate(candidate) > tokenBudget) break;
      out.writeln(line);
    }
    return out.toString().trim();
  }

  static List<String> _decodeAliases(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded
          .map((value) => value?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  static bool _hasExplicitCorrectionIntent(List<Message> recentMessages) {
    final latestUserText = recentMessages.reversed
        .where(
          (message) =>
              message.isUser &&
              !message.isIncomplete &&
              !message.isRpChapterContinuation,
        )
        .map((message) => message.promptVisibleText.trim())
        .firstWhere((text) => text.isNotEmpty, orElse: () => '');
    if (latestUserText.isEmpty) return false;
    return RegExp(
      r'(修正|更正|糾正|纠正|改成|應該是|应该是|不是.+而是|其實是|其实是|'
      r'資料錯|资料错|記錯|记错|correction|correct\s+that|should\s+be|'
      r'not\s+.+but)',
      caseSensitive: false,
    ).hasMatch(latestUserText);
  }

  static Future<void> updateState(
    String id, {
    required String value,
    required String status,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'rp_story_states',
      columns: const <String>['state_type'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final type = rows.first['state_type']?.toString() ?? '';
    if (!_statuses[type]!.contains(status)) {
      throw ArgumentError.value(status, 'status', 'Invalid $type status');
    }
    await db.update(
      'rp_story_states',
      <String, Object?>{
        'value': value.trim(),
        'status': status,
        'user_edited': 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Applies a correction explicitly quoted from the latest user message.
  /// The stable state key must already exist; this path cannot create facts.
  /// Marking it user-edited protects the corrected value from a later summary
  /// pass that still carries the stale version.
  static Future<bool> applyModelCorrection({
    required String characterId,
    required String continuityId,
    required String sourceConversationId,
    required int sourceMessageId,
    required String stateKey,
    required String value,
    required String status,
    required String evidence,
  }) async {
    final normalizedKey = stateKey.trim();
    final normalizedValue = value.trim();
    final normalizedEvidence = evidence.trim();
    if (normalizedKey.isEmpty ||
        normalizedValue.isEmpty ||
        normalizedEvidence.isEmpty) {
      return false;
    }
    final db = await DatabaseHelper.database;
    final scope = _scope(continuityId);
    return db.transaction<bool>((txn) async {
      final rows = await txn.query(
        'rp_story_states',
        where: 'character_id = ? AND continuity_id = ? AND state_key = ?',
        whereArgs: <Object?>[characterId, scope, normalizedKey],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final row = rows.first;
      final type = row['state_type']?.toString() ?? '';
      final normalizedStatus = status.trim().isEmpty
          ? row['status']?.toString() ?? ''
          : status.trim();
      if (!(_statuses[type]?.contains(normalizedStatus) ?? false)) {
        return false;
      }
      return await txn.update(
            'rp_story_states',
            <String, Object?>{
              'value': normalizedValue,
              'status': normalizedStatus,
              'source_conversation_id': sourceConversationId,
              'source_message_ids': jsonEncode(<int>[sourceMessageId]),
              'source_summary_id': null,
              'evidence': '[model_user_correction]$normalizedEvidence',
              'user_edited': 1,
              'updated_at': DateTime.now().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: <Object?>[row['id']],
          ) ==
          1;
    });
  }
}
