import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

const bool _developerDiagnosticsEnabled = bool.fromEnvironment(
  'HOLT_ENABLE_DEVELOPER_DIAGNOSTICS',
  defaultValue: kDebugMode,
);

/// 單次「實際 request 組裝完成後」的 System Context 快照。
///
/// 只保存在記憶體，不寫資料庫／SharedPreferences。API headers 不會傳入；
/// 預覽仍會再遮罩常見 Key 格式，避免診斷畫面與複製報告洩漏憑證。
class SystemContextDebugSnapshot {
  final DateTime capturedAt;
  final String provider;
  final String model;
  final String cacheChannel;
  final String sessionId;
  final String transport;
  final bool cacheEnabled;
  final bool cachePrefixPreserved;
  final bool stablePrefixDrifted;
  final String fallbackReason;
  final List<String> roles;
  final int latestUserIndex;
  final int cacheBreakpointIndex;
  final bool userRoleClean;
  final int stableChars;
  final int liveChars;
  final String stableHash;
  final String liveHash;
  final bool hasTime;
  final bool hasBioClock;
  final bool hasMemory;
  final String stablePreview;
  final String livePreview;
  final String maskedStablePreview;
  final String maskedLivePreview;
  final List<String> warnings;

  const SystemContextDebugSnapshot({
    required this.capturedAt,
    required this.provider,
    required this.model,
    required this.cacheChannel,
    required this.sessionId,
    required this.transport,
    required this.cacheEnabled,
    required this.cachePrefixPreserved,
    required this.stablePrefixDrifted,
    required this.fallbackReason,
    required this.roles,
    required this.latestUserIndex,
    required this.cacheBreakpointIndex,
    required this.userRoleClean,
    required this.stableChars,
    required this.liveChars,
    required this.stableHash,
    required this.liveHash,
    required this.hasTime,
    required this.hasBioClock,
    required this.hasMemory,
    required this.stablePreview,
    required this.livePreview,
    required this.maskedStablePreview,
    required this.maskedLivePreview,
    required this.warnings,
  });

  bool get healthy => warnings.isEmpty;

  String report({bool revealSensitive = false}) {
    final stable = revealSensitive ? stablePreview : maskedStablePreview;
    final live = revealSensitive ? livePreview : maskedLivePreview;
    return <String>[
      'System Context Debug',
      'at: ${capturedAt.toIso8601String()}',
      'provider/model: $provider / $model',
      'channel/session: $cacheChannel / ${sessionId.isEmpty ? '—' : sessionId}',
      'transport: $transport',
      'cache: ${cacheEnabled ? 'on' : 'off'} · prefix ${cachePrefixPreserved ? 'preserved' : 'may refresh'}${stablePrefixDrifted ? ' · DRIFT' : ''}',
      'roles: ${roles.isEmpty ? '—' : roles.join(' > ')}',
      'latest user: $latestUserIndex · breakpoint: $cacheBreakpointIndex · user clean: $userRoleClean',
      'stable: $stableChars chars · $stableHash',
      'live: $liveChars chars · $liveHash',
      'markers: time=$hasTime bioClock=$hasBioClock memory=$hasMemory',
      if (fallbackReason.isNotEmpty) 'fallback: $fallbackReason',
      if (warnings.isNotEmpty) 'warnings:\n- ${warnings.join('\n- ')}',
      '',
      '[stable preview]',
      stable,
      '',
      '[live preview]',
      live,
    ].join('\n');
  }
}

class SystemContextDebug {
  static const int _maxEntries = 20;
  static const int _maxPreviewRunes = 8000;
  static final ValueNotifier<List<SystemContextDebugSnapshot>> snapshots =
      ValueNotifier<List<SystemContextDebugSnapshot>>(
        const <SystemContextDebugSnapshot>[],
      );

  static void clear() {
    snapshots.value = const <SystemContextDebugSnapshot>[];
  }

  static void recordChatRequest({
    required String provider,
    required String model,
    required String cacheChannel,
    required String transport,
    required List<Map<String, String>> sourceMessages,
    required List requestMessages,
    required String stableContext,
    required String liveState,
    String sessionId = '',
    bool cacheEnabled = false,
    bool cachePrefixPreserved = true,
    String fallbackReason = '',
    int cacheBreakpointIndex = -1,
    List<String> topLevelRoles = const <String>[],
    String roleKey = 'role',
    String contentKey = 'content',
    bool expectTime = true,
  }) {
    if (!_developerDiagnosticsEnabled) return;
    final roles = <String>[
      ...topLevelRoles.where((role) => role.trim().isNotEmpty),
      ...requestMessages
          .whereType<Map>()
          .map((message) => '${message[roleKey] ?? ''}')
          .where((role) => role.isNotEmpty),
    ];
    var latestUserIndex = -1;
    for (var i = requestMessages.length - 1; i >= 0; i--) {
      final message = requestMessages[i];
      if (message is Map && message[roleKey] == 'user') {
        latestUserIndex = i + topLevelRoles.length;
        break;
      }
    }

    final sourceUsers = sourceMessages
        .where((message) => message['role'] == 'user')
        .map((message) => message['content'] ?? '')
        .toList(growable: false);
    final requestUsers = requestMessages
        .whereType<Map>()
        .where((message) => message[roleKey] == 'user')
        .map((message) => _textContent(message[contentKey]))
        .toList(growable: false);
    final userRoleClean =
        _sameUserPayloads(sourceUsers, requestUsers) &&
        requestUsers.every((text) => !text.contains('## App Live State'));

    final stableHash = _shortHash(stableContext);
    final liveHash = _shortHash(liveState);
    final previous = snapshots.value
        .cast<SystemContextDebugSnapshot?>()
        .firstWhere(
          (entry) =>
              entry != null &&
              entry.provider == provider &&
              entry.model == model &&
              entry.cacheChannel == cacheChannel &&
              entry.sessionId == sessionId,
          orElse: () => null,
        );
    final stablePrefixDrifted =
        previous != null &&
        previous.stableHash.isNotEmpty &&
        stableHash.isNotEmpty &&
        previous.stableHash != stableHash;

    final normalizedLive = liveState.toLowerCase();
    final hasTime = RegExp(
      r'(當前本地時間|当前本地时间|現在時間|现在时间|current local time|current time|\d{1,2}:\d{2})',
      caseSensitive: false,
    ).hasMatch(liveState);
    // Detect the App-authored section marker only. Recalled memory can
    // legitimately mention habits, meals or fatigue; those words alone do not
    // mean that the bio-clock module was injected into this request.
    final hasBioClock = RegExp(
      r'^###\s*(?:生物鐘(?:變動)?|生物钟(?:变动)?|bio\s*clock(?:\s*changes)?)\s*$',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(liveState);
    final hasMemory = RegExp(
      r'(###\s*(記憶|记忆|memory)|【[^】]*(記憶|记忆|memory)|\[#\d+)',
      caseSensitive: false,
    ).hasMatch(liveState);
    final warnings = <String>[
      if (!userRoleClean) 'USER_ROLE_CONTAMINATED',
      if (latestUserIndex < 0) 'LATEST_USER_MISSING',
      if (liveState.trim().isNotEmpty && transport.trim().isEmpty)
        'LIVE_STATE_TRANSPORT_MISSING',
      if (expectTime && liveState.trim().isNotEmpty && !hasTime)
        'DYNAMIC_TIME_MISSING',
      if (stablePrefixDrifted) 'STABLE_PREFIX_DRIFT',
      if (cacheEnabled && !cachePrefixPreserved) 'CACHE_PREFIX_MAY_REFRESH',
      if (normalizedLive.contains('authorization:') ||
          normalizedLive.contains('api key'))
        'POSSIBLE_SECRET_IN_CONTEXT',
    ];

    final cleanStable = _redactSecrets(_truncate(stableContext));
    final cleanLive = _redactSecrets(_truncate(liveState));
    final snapshot = SystemContextDebugSnapshot(
      capturedAt: DateTime.now(),
      provider: provider,
      model: model,
      cacheChannel: cacheChannel,
      sessionId: sessionId,
      transport: transport,
      cacheEnabled: cacheEnabled,
      cachePrefixPreserved: cachePrefixPreserved,
      stablePrefixDrifted: stablePrefixDrifted,
      fallbackReason: fallbackReason,
      roles: roles,
      latestUserIndex: latestUserIndex,
      cacheBreakpointIndex: cacheBreakpointIndex < 0
          ? -1
          : cacheBreakpointIndex + topLevelRoles.length,
      userRoleClean: userRoleClean,
      stableChars: stableContext.runes.length,
      liveChars: liveState.runes.length,
      stableHash: stableHash,
      liveHash: liveHash,
      hasTime: hasTime,
      hasBioClock: hasBioClock,
      hasMemory: hasMemory,
      stablePreview: cleanStable,
      livePreview: cleanLive,
      maskedStablePreview: _maskPreview(cleanStable),
      maskedLivePreview: _maskPreview(cleanLive),
      warnings: List<String>.unmodifiable(warnings),
    );
    snapshots.value = <SystemContextDebugSnapshot>[
      snapshot,
      ...snapshots.value.take(_maxEntries - 1),
    ];
  }

  static bool _sameUserPayloads(List<String> source, List<String> request) {
    if (source.length != request.length) return false;
    for (var i = 0; i < source.length; i++) {
      if (source[i] == request[i]) continue;
      // 圖片 user 的空 caption 會被 provider 轉成可讀 fallback；它仍是
      // App 明確的圖片操作，不是 runtime context。
      if (source[i].isEmpty &&
          (request[i] == '（用戶發送了一張圖片）' ||
              request[i] == 'The user sent an image.')) {
        continue;
      }
      return false;
    }
    return true;
  }

  static String _textContent(dynamic content) {
    if (content is String) return content;
    if (content is Map) return '${content['text'] ?? ''}';
    if (content is List) {
      return content
          .whereType<Map>()
          .map((block) => '${block['text'] ?? ''}')
          .where((text) => text.isNotEmpty)
          .join('\n');
    }
    return '';
  }

  static String _shortHash(String text) {
    if (text.isEmpty) return '';
    return sha256.convert(utf8.encode(text)).toString().substring(0, 10);
  }

  static String _truncate(String text) {
    final runes = text.runes.toList(growable: false);
    if (runes.length <= _maxPreviewRunes) return text;
    return '${String.fromCharCodes(runes.take(_maxPreviewRunes))}\n… [truncated]';
  }

  static String _redactSecrets(String text) {
    var result = text;
    result = result.replaceAllMapped(
      RegExp(
        r'((?:api[_ -]?key|secret(?:[_ -]?access)?[_ -]?key|authorization)\s*[:=]\s*)([^\s]+)',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    result = result.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+\-/=]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    result = result.replaceAll(
      RegExp(r'\b(?:sk|xai)-[A-Za-z0-9_-]{8,}\b', caseSensitive: false),
      '[REDACTED_KEY]',
    );
    result = result.replaceAll(
      RegExp(r'\bAIza[A-Za-z0-9_-]{12,}\b'),
      '[REDACTED_KEY]',
    );
    return result;
  }

  static String _maskPreview(String text) {
    if (text.trim().isEmpty) return '—';
    final headings = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.startsWith('#'))
        .take(24)
        .toList(growable: false);
    return <String>[
      if (headings.isNotEmpty) ...headings,
      '[content hidden · ${text.runes.length} chars]',
    ].join('\n');
  }
}
