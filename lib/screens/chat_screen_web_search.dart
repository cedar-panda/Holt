// ignore_for_file: invalid_use_of_protected_member

part of 'chat_screen.dart';

extension _ChatWebSearchMethods on _ChatScreenState {
  String _webSearchProviderLabel(ResolvedWebSearchProvider provider) {
    return switch (provider.id) {
      WebSearchProviderId.gemini => L.pick(
        en: 'Gemini · ${provider.model}',
        zhTW: 'Gemini · ${provider.model}',
        zhCN: 'Gemini · ${provider.model}',
      ),
      WebSearchProviderId.openRouter => L.pick(
        en: 'OpenRouter · ${provider.model} · Exa',
        zhTW: 'OpenRouter · ${provider.model} · Exa',
        zhCN: 'OpenRouter · ${provider.model} · Exa',
      ),
      WebSearchProviderId.xai => L.pick(
        en: 'Grok · ${provider.model} · Web Search',
        zhTW: 'Grok · ${provider.model} · 網路搜尋',
        zhCN: 'Grok · ${provider.model} · 网络搜索',
      ),
      WebSearchProviderId.relay => L.pick(
        en: 'Search relay · ${provider.model}',
        zhTW: '搜尋中轉站 · ${provider.model}',
        zhCN: '搜索中转站 · ${provider.model}',
      ),
    };
  }

  void _dismissWebSearchConfirmation() {
    final dialogContext = _webSearchConfirmationContext;
    _webSearchConfirmationContext = null;
    if (dialogContext == null || !dialogContext.mounted) return;
    final navigator = Navigator.of(dialogContext);
    if (navigator.canPop()) navigator.pop(false);
  }

  Future<bool> _confirmWebSearchPlan({
    required String query,
    required ResolvedWebSearchPlan plan,
    required int generationSerial,
  }) async {
    if (!mounted ||
        !_isCurrentGeneration(generationSerial) ||
        _stopGenerationRequested) {
      return false;
    }
    // 使用者已在設定中啟用網路搜尋，自動同意執行，不阻擋串流
    return true;
  }

  WebSearchTurnPlan _webSearchTurnPlan(ResolvedWebSearchPlan resolved) {
    WebSearchProviderRoute routeFor(ResolvedWebSearchProvider provider) {
      final route = switch (provider.id) {
        WebSearchProviderId.gemini => WebSearchProviderRoute.geminiGoogleSearch(
          provider.model,
        ),
        WebSearchProviderId.openRouter => WebSearchProviderRoute.openRouterExa(
          provider.model,
        ),
        WebSearchProviderId.xai => WebSearchProviderRoute.xaiWebSearch(
          provider.model,
        ),
        WebSearchProviderId.relay => WebSearchProviderRoute.relayOpenAiChat(
          provider.model,
        ),
      };
      if (route.route != provider.route) {
        throw const WebSearchProviderException(
          code: WebSearchFailureCode.notConfigured,
          safeMessage: 'The web-search provider route changed unexpectedly.',
          costCertainty: WebSearchCostCertainty.known,
        );
      }
      return route;
    }

    final routes = resolved.providers.map(routeFor).toList(growable: false);
    return routes.length == 2
        ? WebSearchTurnPlan.dual(routes[0], routes[1])
        : WebSearchTurnPlan.single(routes.single);
  }

  void _setWebSearchFailure({
    required int generationSerial,
    required String query,
    required List<String> providers,
    required String safeMessage,
  }) {
    if (providers.isNotEmpty) {
      unawaited(
        AppErrorLogService.record(
          error: StateError(safeMessage),
          trigger: 'functional_search_model_request',
          source: 'functional_model',
          model: providers.join(', '),
        ),
      );
    }
    if (!mounted || !_isCurrentGeneration(generationSerial)) return;
    final activity = _WebSearchActivityState(
      status: WebSearchActivityStatus.failed,
      query: query,
      providers: providers,
      safeMessage: safeMessage,
    );
    _refreshChatState(() {
      _pendingWebSearchFailureContext =
          WebSearchFollowUp.standaloneFailureContext(
            query: query,
            providers: providers,
            safeMessage: safeMessage,
          );
      _webSearchActivity = activity;
    });
    _scrollToBottom();
    Future<void>.delayed(const Duration(seconds: 10), () {
      if (!mounted || !identical(_webSearchActivity, activity)) return;
      _refreshChatState(() => _webSearchActivity = null);
    });
  }

  Future<void> _runWebSearchIntent({
    required String query,
    required int userMessageId,
    required int generationSerial,
  }) async {
    if (!_isCurrentGeneration(generationSerial) || _stopGenerationRequested) {
      return;
    }

    // Credential/format detection happens locally before settings, consent,
    // ToolRunner permission, or any provider code sees the query.
    try {
      WebSearchRequest(
        query: query,
        locale: L.locale,
        sensitiveQueryConfirmed: true,
      );
    } on WebSearchProviderException catch (error) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: error.code == WebSearchFailureCode.secretDetected
            ? L.pick(
                en: 'Blocked sensitive query',
                zhTW: '已攔截敏感查詢',
                zhCN: '已拦截敏感查询',
              )
            : query,
        providers: const <String>[],
        safeMessage: error.safeMessage,
      );
      return;
    }

    ResolvedWebSearchPlan resolvedPlan;
    int dailyProviderLaunchCap;
    int maxResults;
    try {
      final settings = await Future.wait<Object>(<Future<Object>>[
        WebSearchSettings.getEnabled(),
        WebSearchSettings.getMode(),
        WebSearchSettings.getDailyProviderLaunchCap(),
        WebSearchSettings.getMaxResults(),
      ]);
      if (settings[0] != true) {
        _setWebSearchFailure(
          generationSerial: generationSerial,
          query: query,
          providers: const <String>[],
          safeMessage: L.pick(
            en: 'Web search is turned off in API settings.',
            zhTW: '網路搜尋已在 API 設定中關閉。',
            zhCN: '网络搜索已在 API 设置中关闭。',
          ),
        );
        return;
      }
      resolvedPlan = await _webSearchService.resolvePlan(
        settings[1] as WebSearchMode,
      );
      dailyProviderLaunchCap = settings[2] as int;
      maxResults = settings[3] as int;
    } on WebSearchProviderException catch (error) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: query,
        providers: const <String>[],
        safeMessage: error.safeMessage,
      );
      return;
    }

    final providerLabels = resolvedPlan.providers
        .map(_webSearchProviderLabel)
        .toList(growable: false);
    if (resolvedPlan.providers.any(
      (provider) => provider.id == WebSearchProviderId.gemini,
    )) {
      try {
        // Google disallows personal/sensitive data in unpaid API traffic. The
        // App cannot reliably determine the billing state of a BYOK project,
        // so detected PII is blocked for every Gemini grounding request.
        WebSearchRequest(
          query: query,
          locale: L.locale,
          sensitiveQueryConfirmed: false,
        );
      } on WebSearchProviderException catch (error) {
        if (error.code !=
            WebSearchFailureCode.sensitiveQueryConfirmationRequired) {
          rethrow;
        }
        _setWebSearchFailure(
          generationSerial: generationSerial,
          query: L.pick(
            en: 'Blocked personal-data query',
            zhTW: '已攔截個人資料查詢',
            zhCN: '已拦截个人数据查询',
          ),
          providers: providerLabels,
          safeMessage: L.pick(
            en: 'Gemini web search is not allowed to send a query that appears to contain personal data. Edit the request and try again.',
            zhTW: 'Gemini 網路搜尋不會送出疑似包含個人資料的查詢。請修改搜尋請求後再試。',
            zhCN: 'Gemini 网络搜索不会发送疑似包含个人数据的查询。请修改搜索请求后重试。',
          ),
        );
        return;
      }
    }
    final confirmed = await _confirmWebSearchPlan(
      query: query,
      plan: resolvedPlan,
      generationSerial: generationSerial,
    );
    if (!confirmed ||
        !_isCurrentGeneration(generationSerial) ||
        _stopGenerationRequested) {
      return;
    }

    WebSearchTurnGrant? grant;
    var toolStarted = false;
    try {
      final binding = WebSearchTurnBinding(
        conversationId: widget.conversationId,
        characterId: _activeCharacterId,
        turnId: 'message:${userMessageId}_$generationSerial',
        generationSerial: generationSerial,
        query: query,
        locale: L.locale,
        maxResults: maxResults,
        plan: _webSearchTurnPlan(resolvedPlan),
      );
      grant = await _webSearchTurnCoordinator.issueGrant(
        binding: binding,
        dailyProviderLaunchCap: dailyProviderLaunchCap,
      );
      if (!mounted ||
          !_isCurrentGeneration(generationSerial) ||
          _stopGenerationRequested) {
        await _webSearchTurnCoordinator.revokeGrant(grant.id);
        return;
      }
      _refreshChatState(() {
        _webSearchActivity = _WebSearchActivityState(
          status: WebSearchActivityStatus.searching,
          query: binding.query,
          providers: providerLabels,
        );
      });
      _scrollToBottom();

      final call = ToolCall.create(
        name: WebSearchToolBridge.toolName,
        arguments: <String, Object?>{'query': binding.query},
      );
      toolStarted = true;
      final result = await _toolRunner.run(
        call: call,
        context: ToolContext(
          mode: ToolRunMode.live,
          conversationId: widget.conversationId,
          characterId: _activeCharacterId,
          metadata: grant.toContextMetadata(),
        ),
      );
      if (!mounted ||
          !_isCurrentGeneration(generationSerial) ||
          _stopGenerationRequested ||
          result.status == ToolResultStatus.cancelled) {
        return;
      }
      final data = result.data;
      if (result.status == ToolResultStatus.success &&
          data is WebSearchBatchResult) {
        final failureContext = WebSearchFollowUp.failureContextFor(data) ?? '';
        final allFailed = data.allFailed;
        _refreshChatState(() {
          _pendingWebSearchResult = data;
          _pendingWebSearchFailureContext = failureContext;
          // Preserve one visual surface while the model starts composing from
          // the search evidence. It hands off directly to the first streamed
          // response instead of briefly falling back to the generic loader.
          _webSearchActivity = _WebSearchActivityState(
            status: allFailed
                ? WebSearchActivityStatus.failed
                : WebSearchActivityStatus.completed,
            query: binding.query,
            providers: providerLabels,
            safeMessage: allFailed && data.failures.isNotEmpty
                ? data.failures.first.safeMessage
                : '',
          );
        });
        return;
      }
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: binding.query,
        providers: providerLabels,
        safeMessage:
            result.failure?.message ??
            L.pick(
              en: 'Web search was not completed. The normal reply was kept.',
              zhTW: '網路搜尋未完成，已保留原本的回覆。',
              zhCN: '网络搜索未完成，已保留原本的回复。',
            ),
      );
    } on WebSearchTurnCoordinatorException catch (error) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: query,
        providers: providerLabels,
        safeMessage: error.safeMessage,
      );
    } on WebSearchProviderException catch (error) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: query,
        providers: providerLabels,
        safeMessage: error.safeMessage,
      );
    } catch (_) {
      _setWebSearchFailure(
        generationSerial: generationSerial,
        query: query,
        providers: providerLabels,
        safeMessage: L.pick(
          en: 'Web search was not completed. The normal reply was kept.',
          zhTW: '網路搜尋未完成，已保留原本的回覆。',
          zhCN: '网络搜索未完成，已保留原本的回复。',
        ),
      );
    } finally {
      if (grant != null && !toolStarted) {
        await _webSearchTurnCoordinator.revokeGrant(grant.id);
      }
    }
  }
}
