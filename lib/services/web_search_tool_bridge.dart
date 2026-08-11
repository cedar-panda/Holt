import 'tool_runner.dart';
import 'settings/web_search_settings.dart';
import 'web_search_service.dart';
import 'web_search_turn_coordinator.dart';

/// Production composition boundary between ToolRunner, one-shot consent, the
/// provider-launch ledger, and the typed web-search service.
///
/// The only authorization value accepted from [ToolContext] is an opaque,
/// one-use grant id. Query, locale, model and provider routes come back from
/// the coordinator claim, so mutable metadata cannot change what was approved.
class WebSearchToolBridge {
  const WebSearchToolBridge({required this.service, required this.coordinator});

  static const String toolName = 'web.search';

  final HybridWebSearchService service;
  final WebSearchTurnCoordinator coordinator;

  ToolDefinition createDefinition() {
    return ToolDefinition(
      name: toolName,
      description:
          'Search the public web and return separate, structured provider results.',
      permission: ToolPermissionRequirement.network,
      timeout: const Duration(seconds: 45),
      validateArguments: _validateArguments,
      liveHandler: _runLive,
    );
  }

  Future<ToolPermissionDecision> requestPermission({
    required ToolCall call,
    required ToolDefinition definition,
    required ToolContext context,
    required ToolCancellationToken cancellationToken,
  }) async {
    cancellationToken.throwIfCancelled();
    if (!webSearchLiveDeveloperPreviewEnabled) {
      return ToolPermissionDecision.deny;
    }
    if (call.name != toolName ||
        context.mode != ToolRunMode.live ||
        definition.permissionForMode(context.mode) !=
            ToolPermissionRequirement.network) {
      return ToolPermissionDecision.deny;
    }
    final grantId = context.metadata[WebSearchTurnGrant.metadataKey];
    final query = call.arguments['query'];
    final conversationId = context.conversationId;
    final characterId = context.characterId;
    if (grantId is! String ||
        query is! String ||
        conversationId == null ||
        characterId == null) {
      return ToolPermissionDecision.deny;
    }
    final allowed = await coordinator.consumeForPermission(
      grantId: grantId,
      callId: call.id,
      conversationId: conversationId,
      characterId: characterId,
      query: query,
    );
    cancellationToken.throwIfCancelled();
    return allowed ? ToolPermissionDecision.allow : ToolPermissionDecision.deny;
  }

  static String? _validateArguments(Map<String, Object?> arguments) {
    if (arguments.length != 1 || !arguments.containsKey('query')) {
      return 'web.search accepts only a query argument.';
    }
    final query = arguments['query'];
    if (query is! String || query.trim().isEmpty) {
      return 'web.search requires a non-empty query.';
    }
    try {
      // This local preflight runs before ToolRunner asks its permission policy,
      // so obvious credentials never reach a future permission logger.
      WebSearchRequest(query: query, sensitiveQueryConfirmed: true);
      return null;
    } on WebSearchProviderException {
      return 'web.search blocked an unsafe or invalid query.';
    }
  }

  Future<Object?> _runLive(
    ToolCall call,
    ToolContext context,
    ToolCancellationToken cancellationToken,
  ) async {
    if (!webSearchLiveDeveloperPreviewEnabled) {
      throw ToolReportedException(
        safeMessage: 'Live web search is disabled in this build.',
        domainCode: 'web.search.live_disabled',
      );
    }
    WebSearchExecutionClaim? claim;
    var finished = false;
    try {
      claim = await coordinator.claimForHandler(call.id);
      if (claim == null || claim.mode != WebSearchTurnRunMode.live) {
        throw ToolReportedException(
          safeMessage: 'Web search authorization expired or was already used.',
          domainCode: 'web.search.grant_rejected',
        );
      }
      final authorizedClaim = claim;
      cancellationToken.throwIfCancelled();
      final query = call.arguments['query']! as String;
      if (WebSearchTurnBinding.normalizeQuery(query) != authorizedClaim.query) {
        throw ToolReportedException(
          safeMessage: 'Web search authorization does not match this query.',
          domainCode: 'web.search.grant_mismatch',
        );
      }

      final plan = _resolvedPlan(authorizedClaim);
      final request = WebSearchRequest(
        query: authorizedClaim.query,
        locale: authorizedClaim.locale,
        maxResults: authorizedClaim.maxResults,
        // A BYOK app cannot prove whether a Gemini project is using paid
        // quota. Keep the no-personal-data rule enforceable at the execution
        // boundary even if a future caller skips the chat-screen preflight.
        sensitiveQueryConfirmed: !plan.providers.any(
          (provider) => provider.id == WebSearchProviderId.gemini,
        ),
        allowedProviders: plan.allowedProviders,
      );
      final batch = await service.searchResolvedPlan(
        request,
        cancellationToken,
        plan: plan,
        beforeProviderDispatch: (provider) async {
          final route = _claimRouteFor(authorizedClaim, provider);
          await coordinator.markProviderLaunched(
            claim: authorizedClaim,
            route: route,
          );
        },
      );
      cancellationToken.throwIfCancelled();
      for (final outcome in batch.outcomes) {
        final route = _claimRouteForProvider(authorizedClaim, outcome.provider);
        await coordinator.settleProvider(
          claim: authorizedClaim,
          route: route,
          settlement: _settlementFor(outcome),
        );
      }
      await coordinator.finishExecution(authorizedClaim);
      finished = true;
      return batch;
    } on ToolCancelledException {
      rethrow;
    } on WebSearchProviderException catch (error) {
      throw ToolReportedException(
        safeMessage: error.safeMessage,
        retryable: error.retryable,
        domainCode: _domainCode(error.code),
        safeDetails: <String, Object?>{
          if (error.statusCode != null) 'httpStatus': error.statusCode,
          'costCertainty': error.costCertainty.name,
        },
      );
    } on WebSearchTurnCoordinatorException catch (error) {
      throw ToolReportedException(
        safeMessage: error.safeMessage,
        domainCode: 'web.search.ledger_${error.code.name}',
      );
    } finally {
      final activeClaim = claim;
      if (activeClaim != null && !finished) {
        try {
          await coordinator.finishExecution(activeClaim);
        } catch (_) {
          // The coordinator already fails closed and keeps dispatched costs as
          // unknown. Cleanup must not replace cancellation/provider semantics
          // with raw storage diagnostics.
        }
      }
    }
  }

  ResolvedWebSearchPlan _resolvedPlan(WebSearchExecutionClaim claim) {
    final providers = <ResolvedWebSearchProvider>[
      for (final route in claim.routes)
        ResolvedWebSearchProvider(
          id: switch (route.provider) {
            WebSearchTurnProvider.openRouter => WebSearchProviderId.openRouter,
            WebSearchTurnProvider.gemini => WebSearchProviderId.gemini,
          },
          model: route.model,
          route: route.route,
        ),
    ];
    final mode = claim.plan.strategy == WebSearchPlanStrategy.dual
        ? WebSearchMode.dual
        : switch (providers.single.id) {
            WebSearchProviderId.openRouter => WebSearchMode.openRouter,
            WebSearchProviderId.gemini => WebSearchMode.gemini,
          };
    return ResolvedWebSearchPlan(mode: mode, providers: providers);
  }

  WebSearchProviderRoute _claimRouteFor(
    WebSearchExecutionClaim claim,
    ResolvedWebSearchProvider provider,
  ) {
    return claim.routes.singleWhere(
      (route) =>
          route.providerName == provider.id.name &&
          route.model == provider.model &&
          route.route == provider.route,
      orElse: () => throw const WebSearchTurnCoordinatorException(
        WebSearchTurnCoordinatorError.routeRejected,
        'The approved web-search route changed before dispatch.',
      ),
    );
  }

  WebSearchProviderRoute _claimRouteForProvider(
    WebSearchExecutionClaim claim,
    WebSearchProviderId provider,
  ) {
    final providerName = provider.name;
    return claim.routes.singleWhere(
      (route) => route.providerName == providerName,
      orElse: () => throw const WebSearchTurnCoordinatorException(
        WebSearchTurnCoordinatorError.routeRejected,
        'The web-search result did not match its approved route.',
      ),
    );
  }

  WebSearchProviderSettlement _settlementFor(WebSearchProviderOutcome outcome) {
    final result = outcome.result;
    if (result != null) {
      final usage = result.usage;
      final knownCost =
          usage.costCertainty == WebSearchCostCertainty.known &&
          usage.actualCostUsd != null;
      return WebSearchProviderSettlement(
        outcome: WebSearchProviderLaunchOutcome.success,
        searchRequests: usage.searchRequests,
        promptTokens: usage.promptTokens,
        completionTokens: usage.completionTokens,
        actualCostUsd: knownCost ? usage.actualCostUsd : null,
        costCertainty: knownCost
            ? WebSearchLedgerCostCertainty.known
            : WebSearchLedgerCostCertainty.unknown,
      );
    }
    final failure = outcome.failure!;
    final knownCost = failure.costCertainty == WebSearchCostCertainty.known;
    return WebSearchProviderSettlement(
      outcome: WebSearchProviderLaunchOutcome.failure,
      actualCostUsd: knownCost ? 0 : null,
      costCertainty: knownCost
          ? WebSearchLedgerCostCertainty.known
          : WebSearchLedgerCostCertainty.unknown,
    );
  }

  static String _domainCode(WebSearchFailureCode code) => switch (code) {
    WebSearchFailureCode.invalidQuery => 'web.search.invalid_query',
    WebSearchFailureCode.sensitiveQueryConfirmationRequired =>
      'web.search.sensitive_confirmation_required',
    WebSearchFailureCode.providerConsentRequired =>
      'web.search.provider_consent_required',
    WebSearchFailureCode.secretDetected => 'web.search.secret_detected',
    WebSearchFailureCode.notConfigured => 'web.search.not_configured',
    WebSearchFailureCode.unsupportedModel => 'web.search.unsupported_model',
    WebSearchFailureCode.authentication => 'web.search.authentication',
    WebSearchFailureCode.billing => 'web.search.billing',
    WebSearchFailureCode.rateLimited => 'web.search.rate_limited',
    WebSearchFailureCode.unavailable => 'web.search.unavailable',
    WebSearchFailureCode.redirectRejected => 'web.search.redirect_rejected',
    WebSearchFailureCode.responseTooLarge => 'web.search.response_too_large',
    WebSearchFailureCode.invalidResponse => 'web.search.invalid_response',
    WebSearchFailureCode.ungrounded => 'web.search.ungrounded',
  };
}
