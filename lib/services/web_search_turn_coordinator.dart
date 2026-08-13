import 'dart:convert';
import 'dart:math';

import '../memory/database.dart';

/// A resolved provider plan. `auto` must be resolved before a grant is issued.
enum WebSearchPlanStrategy { single, dual }

enum WebSearchTurnRunMode { live, replay }

enum WebSearchTurnProvider { openRouter, gemini, xai, relay }

enum WebSearchProviderLaunchOutcome { success, failure, cancelled, unknown }

enum WebSearchLedgerCostCertainty { known, unknown }

enum WebSearchTurnCoordinatorError {
  duplicateLogicalCall,
  dailyBudgetExceeded,
  claimRejected,
  routeRejected,
  ledgerConflict,
}

class WebSearchTurnCoordinatorException implements Exception {
  const WebSearchTurnCoordinatorException(this.code, this.safeMessage);

  final WebSearchTurnCoordinatorError code;
  final String safeMessage;

  @override
  String toString() => safeMessage;
}

/// A fixed, user-visible provider route. Callers cannot construct arbitrary
/// route strings after permission has been granted.
class WebSearchProviderRoute {
  WebSearchProviderRoute._(this.provider, String model, this.route)
    : model = _validateModel(model);

  factory WebSearchProviderRoute.openRouterExa(String model) =>
      WebSearchProviderRoute._(
        WebSearchTurnProvider.openRouter,
        model,
        'openrouter:web_search:exa:zdr-no-fallback',
      );

  factory WebSearchProviderRoute.geminiGoogleSearch(String model) =>
      WebSearchProviderRoute._(
        WebSearchTurnProvider.gemini,
        model,
        'gemini:google_search',
      );

  factory WebSearchProviderRoute.xaiWebSearch(String model) =>
      WebSearchProviderRoute._(
        WebSearchTurnProvider.xai,
        model,
        'xai:web_search',
      );

  factory WebSearchProviderRoute.relayOpenAiChat(String model) =>
      WebSearchProviderRoute._(
        WebSearchTurnProvider.relay,
        model,
        'relay:openai_chat_completions',
      );

  final WebSearchTurnProvider provider;
  final String model;
  final String route;

  String get providerName => provider.name;

  @override
  bool operator ==(Object other) =>
      other is WebSearchProviderRoute &&
      other.provider == provider &&
      other.model == model &&
      other.route == route;

  @override
  int get hashCode => Object.hash(provider, model, route);

  static String _validateModel(String value) {
    final model = value.trim();
    if (model.isEmpty ||
        model.runes.length > 128 ||
        _hasUnsafeControls(model)) {
      throw ArgumentError.value(value, 'model', 'Invalid provider model.');
    }
    return model;
  }
}

/// Immutable, ordered provider plan. Dual mode is two explicit dispatches,
/// never an implicit fallback hidden behind a single-provider permission.
class WebSearchTurnPlan {
  WebSearchTurnPlan.single(WebSearchProviderRoute route)
    : strategy = WebSearchPlanStrategy.single,
      routes = List<WebSearchProviderRoute>.unmodifiable(
        <WebSearchProviderRoute>[route],
      );

  WebSearchTurnPlan.dual(
    WebSearchProviderRoute first,
    WebSearchProviderRoute second,
  ) : strategy = WebSearchPlanStrategy.dual,
      routes = List<WebSearchProviderRoute>.unmodifiable(
        <WebSearchProviderRoute>[first, second],
      ) {
    if (first.provider == second.provider || first.route == second.route) {
      throw ArgumentError('A dual web-search plan requires distinct routes.');
    }
  }

  final WebSearchPlanStrategy strategy;
  final List<WebSearchProviderRoute> routes;

  @override
  bool operator ==(Object other) {
    if (other is! WebSearchTurnPlan || other.strategy != strategy) return false;
    if (other.routes.length != routes.length) return false;
    for (var index = 0; index < routes.length; index++) {
      if (other.routes[index] != routes[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(strategy, Object.hashAll(routes));
}

/// Everything an approval is bound to. Query and locale are normalized once;
/// permission re-checks the runtime query while every remaining field stays
/// authoritative in the one-shot grant returned to the handler.
class WebSearchTurnBinding {
  WebSearchTurnBinding({
    required String conversationId,
    required String characterId,
    required String turnId,
    required this.generationSerial,
    required String query,
    required String locale,
    required this.maxResults,
    required this.plan,
  }) : conversationId = _validateOpaqueId(conversationId, 'conversationId'),
       characterId = _validateOpaqueId(characterId, 'characterId'),
       turnId = _validateOpaqueId(turnId, 'turnId'),
       query = normalizeQuery(query),
       locale = normalizeLocale(locale) {
    if (generationSerial < 0) {
      throw ArgumentError.value(
        generationSerial,
        'generationSerial',
        'Generation serial must not be negative.',
      );
    }
    if (maxResults < 1 || maxResults > 20) {
      throw ArgumentError.value(
        maxResults,
        'maxResults',
        'Web search result limit must be between 1 and 20.',
      );
    }
  }

  static const int maxQueryRunes = 240;

  final String conversationId;
  final String characterId;
  final String turnId;
  final int generationSerial;
  final String query;
  final String locale;
  final int maxResults;
  final WebSearchTurnPlan plan;

  static String normalizeQuery(String raw) {
    if (_hasUnsafeControls(raw)) {
      throw ArgumentError.value(raw, 'query', 'Query contains control text.');
    }
    final normalized = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty || normalized.runes.length > maxQueryRunes) {
      throw ArgumentError.value(
        raw,
        'query',
        'Query must contain 1 to $maxQueryRunes characters.',
      );
    }
    return normalized;
  }

  static String normalizeLocale(String raw) {
    if (_hasUnsafeControls(raw)) {
      throw ArgumentError.value(raw, 'locale', 'Locale contains control text.');
    }
    final parts = raw.trim().replaceAll('_', '-').split('-');
    final normalized = <String>[
      if (parts.isNotEmpty) parts.first.toLowerCase(),
      for (final part in parts.skip(1))
        part.length == 2 ? part.toUpperCase() : part,
    ].join('-');
    if (!RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$').hasMatch(normalized)) {
      throw ArgumentError.value(raw, 'locale', 'Invalid web search locale.');
    }
    return normalized;
  }

  @override
  bool operator ==(Object other) =>
      other is WebSearchTurnBinding &&
      other.conversationId == conversationId &&
      other.characterId == characterId &&
      other.turnId == turnId &&
      other.generationSerial == generationSerial &&
      other.query == query &&
      other.locale == locale &&
      other.maxResults == maxResults &&
      other.plan == plan;

  @override
  int get hashCode => Object.hash(
    conversationId,
    characterId,
    turnId,
    generationSerial,
    query,
    locale,
    maxResults,
    plan,
  );
}

class WebSearchTurnGrant {
  const WebSearchTurnGrant._({
    required this.id,
    required this.reservationId,
    required this.mode,
    required this.binding,
    required this.budgetDay,
    required this.expiresAt,
  });

  static const String metadataKey = 'web_search_turn_grant_id';

  final String id;
  final String reservationId;
  final WebSearchTurnRunMode mode;
  final WebSearchTurnBinding binding;
  final String budgetDay;
  final DateTime expiresAt;

  String get conversationId => binding.conversationId;
  String get characterId => binding.characterId;
  String get turnId => binding.turnId;
  int get generationSerial => binding.generationSerial;
  String get query => binding.query;
  String get locale => binding.locale;
  int get maxResults => binding.maxResults;
  WebSearchTurnPlan get plan => binding.plan;

  Map<String, Object?> toContextMetadata() => <String, Object?>{
    metadataKey: id,
  };
}

/// Opaque proof that permission was consumed and the handler claimed this
/// ToolCall. Its bound fields, rather than mutable call arguments, should drive
/// the provider request.
class WebSearchExecutionClaim {
  const WebSearchExecutionClaim._({
    required this.callId,
    required this.reservationId,
    required this.mode,
    required this.binding,
  });

  final String callId;
  final String reservationId;
  final WebSearchTurnRunMode mode;
  final WebSearchTurnBinding binding;

  String get conversationId => binding.conversationId;
  String get characterId => binding.characterId;
  String get turnId => binding.turnId;
  int get generationSerial => binding.generationSerial;
  String get query => binding.query;
  String get locale => binding.locale;
  int get maxResults => binding.maxResults;
  WebSearchTurnPlan get plan => binding.plan;
  List<WebSearchProviderRoute> get routes => binding.plan.routes;
}

class WebSearchProviderSettlement {
  WebSearchProviderSettlement({
    required this.outcome,
    this.searchRequests = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.actualCostUsd,
    this.costCertainty = WebSearchLedgerCostCertainty.unknown,
  }) {
    if (searchRequests < 0 || promptTokens < 0 || completionTokens < 0) {
      throw ArgumentError('Web-search usage values must not be negative.');
    }
    final cost = actualCostUsd;
    if (cost != null && (!cost.isFinite || cost < 0)) {
      throw ArgumentError.value(
        cost,
        'actualCostUsd',
        'Actual cost must be finite and non-negative.',
      );
    }
    if (costCertainty == WebSearchLedgerCostCertainty.known && cost == null) {
      throw ArgumentError(
        'Known cost certainty requires an actual cost value.',
      );
    }
  }

  final WebSearchProviderLaunchOutcome outcome;
  final int searchRequests;
  final int promptTokens;
  final int completionTokens;
  final double? actualCostUsd;
  final WebSearchLedgerCostCertainty costCertainty;
}

/// One-shot permission and provider-launch ledger coordinator.
///
/// Grants and exact queries only live in memory. SQLite contains one row per
/// provider route so dual reservation, per-day capacity, and settlement are
/// auditable without storing query text, sources, result content, or keys.
class WebSearchTurnCoordinator {
  WebSearchTurnCoordinator({
    DateTime Function()? clock,
    String Function()? randomToken,
    this.grantTtl = const Duration(seconds: 45),
    this.executionLease = const Duration(minutes: 2),
  }) : _clock = clock ?? DateTime.now,
       _randomToken = randomToken ?? _secureToken {
    if (grantTtl <= Duration.zero || grantTtl > const Duration(minutes: 2)) {
      throw ArgumentError.value(
        grantTtl,
        'grantTtl',
        'Grant TTL must be between zero and two minutes.',
      );
    }
    if (executionLease <= Duration.zero ||
        executionLease > const Duration(minutes: 5)) {
      throw ArgumentError.value(
        executionLease,
        'executionLease',
        'Execution lease must be between zero and five minutes.',
      );
    }
  }

  static const int defaultDailyProviderLaunchCap = 20;
  static const int maxDailyProviderLaunchCap = 100;

  final DateTime Function() _clock;
  final String Function() _randomToken;
  final Duration grantTtl;
  final Duration executionLease;
  final Map<String, _IssuedGrant> _issued = <String, _IssuedGrant>{};
  final Map<String, _AuthorizedCall> _authorized = <String, _AuthorizedCall>{};
  final Map<String, _ExecutionState> _active = <String, _ExecutionState>{};
  final Set<String> _usedCallIds = <String>{};
  final Set<String> _replayTurnKeys = <String>{};

  Future<WebSearchTurnGrant> issueGrant({
    required WebSearchTurnBinding binding,
    WebSearchTurnRunMode mode = WebSearchTurnRunMode.live,
    int dailyProviderLaunchCap = defaultDailyProviderLaunchCap,
  }) async {
    if (dailyProviderLaunchCap < 1 ||
        dailyProviderLaunchCap > maxDailyProviderLaunchCap) {
      throw ArgumentError.value(
        dailyProviderLaunchCap,
        'dailyProviderLaunchCap',
        'Daily provider-launch cap must be between 1 and '
            '$maxDailyProviderLaunchCap.',
      );
    }
    final now = _clock();
    await _purgeExpired(now);
    final grantId = _newId('wsg');
    final reservationId = _newId(
      mode == WebSearchTurnRunMode.live ? 'wsr' : 'wrr',
    );
    final expiresAt = now.add(grantTtl);
    final budgetDay = _budgetDay(now);

    if (mode == WebSearchTurnRunMode.live) {
      final result = await DatabaseHelper.reserveWebSearchProviderLaunches(
        reservationId: reservationId,
        conversationId: binding.conversationId,
        characterId: binding.characterId,
        turnId: binding.turnId,
        generationSerial: binding.generationSerial,
        planStrategy: binding.plan.strategy.name,
        routes: <({String provider, String model, String route})>[
          for (final route in binding.plan.routes)
            (
              provider: route.providerName,
              model: route.model,
              route: route.route,
            ),
        ],
        budgetDay: budgetDay,
        dailyProviderLaunchCap: dailyProviderLaunchCap,
        reservedAt: now.toUtc().toIso8601String(),
        expiresAt: expiresAt.toUtc().toIso8601String(),
      );
      switch (result) {
        case WebSearchUsageReservationResult.reserved:
          break;
        case WebSearchUsageReservationResult.duplicateTurn:
          throw const WebSearchTurnCoordinatorException(
            WebSearchTurnCoordinatorError.duplicateLogicalCall,
            'This turn already reserved a web search.',
          );
        case WebSearchUsageReservationResult.dailyLimitExceeded:
          throw const WebSearchTurnCoordinatorException(
            WebSearchTurnCoordinatorError.dailyBudgetExceeded,
            'The daily web-search provider launch limit has been reached.',
          );
      }
    } else {
      final turnKey = _turnKey(binding);
      if (!_replayTurnKeys.add(turnKey)) {
        throw const WebSearchTurnCoordinatorException(
          WebSearchTurnCoordinatorError.duplicateLogicalCall,
          'This replay turn already reserved a web search.',
        );
      }
    }

    final grant = WebSearchTurnGrant._(
      id: grantId,
      reservationId: reservationId,
      mode: mode,
      binding: binding,
      budgetDay: budgetDay,
      expiresAt: expiresAt,
    );
    _issued[grant.id] = _IssuedGrant(grant);
    return grant;
  }

  /// Permission-policy boundary. Context contributes only stable turn identity
  /// plus the ToolCall query; locale, result limit, model, and provider routes
  /// remain authoritative in the in-memory grant and are never copied into
  /// mutable metadata. Every attempted consumption burns the grant.
  Future<bool> consumeForPermission({
    required String grantId,
    required String callId,
    required String conversationId,
    required String characterId,
    required String query,
    String? turnId,
    int? generationSerial,
  }) async {
    _validateCallId(callId);
    final state = _issued.remove(grantId);
    if (state == null) return false;
    final grant = state.grant;
    final now = _clock();
    String normalizedConversationId;
    String normalizedCharacterId;
    String normalizedQuery;
    String? normalizedTurnId;
    try {
      normalizedConversationId = _validateOpaqueId(
        conversationId,
        'conversationId',
      );
      normalizedCharacterId = _validateOpaqueId(characterId, 'characterId');
      normalizedQuery = WebSearchTurnBinding.normalizeQuery(query);
      normalizedTurnId = turnId == null
          ? null
          : _validateOpaqueId(turnId, 'turnId');
    } on ArgumentError {
      await _releaseGrant(grant, now);
      return false;
    }
    final binding = grant.binding;
    if (!now.isBefore(grant.expiresAt) ||
        binding.conversationId != normalizedConversationId ||
        binding.characterId != normalizedCharacterId ||
        binding.query != normalizedQuery ||
        (normalizedTurnId != null && binding.turnId != normalizedTurnId) ||
        (generationSerial != null &&
            binding.generationSerial != generationSerial) ||
        _usedCallIds.contains(callId) ||
        _authorized.containsKey(callId) ||
        _active.containsKey(callId)) {
      await _releaseGrant(grant, now);
      return false;
    }

    if (grant.mode == WebSearchTurnRunMode.live) {
      final bound = await DatabaseHelper.bindWebSearchReservationToCall(
        reservationId: grant.reservationId,
        callId: callId,
        now: now.toUtc().toIso8601String(),
      );
      if (!bound) {
        await _releaseGrant(grant, now);
        return false;
      }
    }
    _usedCallIds.add(callId);
    _authorized[callId] = _AuthorizedCall(grant);
    return true;
  }

  /// Handler boundary. A successful permission decision can be claimed once.
  Future<WebSearchExecutionClaim?> claimForHandler(String callId) async {
    _validateCallId(callId);
    final authorized = _authorized.remove(callId);
    if (authorized == null) return null;
    final grant = authorized.grant;
    final now = _clock();
    if (!now.isBefore(grant.expiresAt)) {
      await _releaseGrant(grant, now, callId: callId);
      return null;
    }
    if (grant.mode == WebSearchTurnRunMode.live &&
        grant.budgetDay != _budgetDay(now)) {
      await _releaseGrant(grant, now, callId: callId);
      return null;
    }
    if (grant.mode == WebSearchTurnRunMode.live) {
      final claimed = await DatabaseHelper.claimWebSearchReservation(
        reservationId: grant.reservationId,
        callId: callId,
        budgetDay: grant.budgetDay,
        claimedAt: now.toUtc().toIso8601String(),
        executionExpiresAt: now.add(executionLease).toUtc().toIso8601String(),
      );
      if (!claimed) {
        await _releaseGrant(grant, now, callId: callId);
        return null;
      }
    }
    final claim = WebSearchExecutionClaim._(
      callId: callId,
      reservationId: grant.reservationId,
      mode: grant.mode,
      binding: grant.binding,
    );
    _active[callId] = _ExecutionState(claim);
    return claim;
  }

  /// Records a billable/provider-visible dispatch. Call immediately before the
  /// HTTP request, not after a response arrives.
  Future<void> markProviderLaunched({
    required WebSearchExecutionClaim claim,
    required WebSearchProviderRoute route,
  }) async {
    final execution = _requireExecution(claim);
    if (claim.mode != WebSearchTurnRunMode.live) {
      throw const WebSearchTurnCoordinatorException(
        WebSearchTurnCoordinatorError.routeRejected,
        'Replay execution cannot launch a network provider.',
      );
    }
    final routeState = execution.routes[route];
    if (routeState != _ProviderRouteState.claimed) {
      throw const WebSearchTurnCoordinatorException(
        WebSearchTurnCoordinatorError.routeRejected,
        'This provider route is absent or was already launched.',
      );
    }
    execution.routes[route] = _ProviderRouteState.transitioning;
    try {
      final launched = await DatabaseHelper.markWebSearchProviderLaunched(
        reservationId: claim.reservationId,
        callId: claim.callId,
        provider: route.providerName,
        providerModel: route.model,
        providerRoute: route.route,
        launchedAt: _clock().toUtc().toIso8601String(),
      );
      if (!launched) {
        throw const WebSearchTurnCoordinatorException(
          WebSearchTurnCoordinatorError.ledgerConflict,
          'The provider launch could not be recorded.',
        );
      }
      execution.routes[route] = _ProviderRouteState.launched;
    } catch (_) {
      execution.routes[route] = _ProviderRouteState.claimed;
      rethrow;
    }
  }

  Future<void> settleProvider({
    required WebSearchExecutionClaim claim,
    required WebSearchProviderRoute route,
    required WebSearchProviderSettlement settlement,
  }) async {
    final execution = _requireExecution(claim);
    if (execution.routes[route] != _ProviderRouteState.launched) {
      throw const WebSearchTurnCoordinatorException(
        WebSearchTurnCoordinatorError.routeRejected,
        'Only a launched provider route can be settled.',
      );
    }
    execution.routes[route] = _ProviderRouteState.transitioning;
    try {
      final settled = await DatabaseHelper.settleWebSearchProviderLaunch(
        reservationId: claim.reservationId,
        callId: claim.callId,
        provider: route.providerName,
        providerModel: route.model,
        providerRoute: route.route,
        outcome: settlement.outcome.name,
        settledAt: _clock().toUtc().toIso8601String(),
        searchRequests: settlement.searchRequests,
        promptTokens: settlement.promptTokens,
        completionTokens: settlement.completionTokens,
        actualCostUsd: settlement.actualCostUsd,
        costCertainty: settlement.costCertainty.name,
      );
      if (!settled) {
        throw const WebSearchTurnCoordinatorException(
          WebSearchTurnCoordinatorError.ledgerConflict,
          'The provider launch could not be settled.',
        );
      }
      execution.routes[route] = _ProviderRouteState.settled;
    } catch (_) {
      execution.routes[route] = _ProviderRouteState.launched;
      rethrow;
    }
  }

  /// Completes a handler run. Unsettled launches become `unknown`; authorized
  /// routes that were never dispatched are released and do not count as use.
  Future<void> finishExecution(WebSearchExecutionClaim claim) async {
    final execution = _requireExecution(claim);
    if (execution.routes.values.contains(_ProviderRouteState.transitioning)) {
      throw const WebSearchTurnCoordinatorException(
        WebSearchTurnCoordinatorError.ledgerConflict,
        'A provider ledger transition is still in progress.',
      );
    }
    if (claim.mode == WebSearchTurnRunMode.live) {
      final unsettled = <WebSearchProviderRoute>[
        for (final entry in execution.routes.entries)
          if (entry.value == _ProviderRouteState.launched) entry.key,
      ];
      for (final route in unsettled) {
        await settleProvider(
          claim: claim,
          route: route,
          settlement: WebSearchProviderSettlement(
            outcome: WebSearchProviderLaunchOutcome.unknown,
          ),
        );
      }
      await DatabaseHelper.releaseUnlaunchedWebSearchReservation(
        reservationId: claim.reservationId,
        callId: claim.callId,
        settledAt: _clock().toUtc().toIso8601String(),
      );
    }
    _active.remove(claim.callId);
  }

  /// Explicitly drops a grant before permission consumption.
  Future<bool> revokeGrant(String grantId) async {
    final state = _issued.remove(grantId);
    if (state == null) return false;
    await _releaseGrant(state.grant, _clock());
    return true;
  }

  _ExecutionState _requireExecution(WebSearchExecutionClaim claim) {
    final execution = _active[claim.callId];
    if (execution == null || !identical(execution.claim, claim)) {
      throw const WebSearchTurnCoordinatorException(
        WebSearchTurnCoordinatorError.claimRejected,
        'The web-search execution claim is invalid or already finished.',
      );
    }
    return execution;
  }

  Future<void> _purgeExpired(DateTime now) async {
    final expiredGrants = <WebSearchTurnGrant>[];
    _issued.removeWhere((_, state) {
      final expired = !now.isBefore(state.grant.expiresAt);
      if (expired) expiredGrants.add(state.grant);
      return expired;
    });
    _authorized.removeWhere((_, state) {
      final expired = !now.isBefore(state.grant.expiresAt);
      if (expired) expiredGrants.add(state.grant);
      return expired;
    });
    for (final grant in expiredGrants) {
      await _releaseGrant(grant, now);
    }
  }

  Future<void> _releaseGrant(
    WebSearchTurnGrant grant,
    DateTime now, {
    String? callId,
  }) async {
    if (grant.mode == WebSearchTurnRunMode.live) {
      await DatabaseHelper.releaseUnlaunchedWebSearchReservation(
        reservationId: grant.reservationId,
        callId: callId,
        settledAt: now.toUtc().toIso8601String(),
      );
    }
  }

  String _newId(String prefix) {
    final token = _randomToken();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(token)) {
      throw StateError('The web-search token factory returned an invalid id.');
    }
    return '${prefix}_$token';
  }

  static String _turnKey(WebSearchTurnBinding binding) =>
      '${binding.conversationId}\u0000${binding.turnId}\u0000'
      '${binding.generationSerial}';

  static String _budgetDay(DateTime now) {
    final local = now.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static String _secureToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class _IssuedGrant {
  const _IssuedGrant(this.grant);

  final WebSearchTurnGrant grant;
}

class _AuthorizedCall {
  const _AuthorizedCall(this.grant);

  final WebSearchTurnGrant grant;
}

enum _ProviderRouteState { claimed, transitioning, launched, settled }

class _ExecutionState {
  _ExecutionState(this.claim)
    : routes = <WebSearchProviderRoute, _ProviderRouteState>{
        for (final route in claim.routes) route: _ProviderRouteState.claimed,
      };

  final WebSearchExecutionClaim claim;
  final Map<WebSearchProviderRoute, _ProviderRouteState> routes;
}

String _validateOpaqueId(String value, String name) {
  if (value.trim().isEmpty ||
      value.trim() != value ||
      value.runes.length > 128 ||
      _hasUnsafeControls(value)) {
    throw ArgumentError.value(value, name, 'Invalid web-search binding id.');
  }
  return value;
}

void _validateCallId(String callId) {
  if (!RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(callId)) {
    throw ArgumentError.value(callId, 'callId', 'Invalid ToolCall id.');
  }
}

bool _hasUnsafeControls(String value) =>
    RegExp(r'[\x00-\x1F\x7F\u202A-\u202E\u2066-\u2069]').hasMatch(value);
