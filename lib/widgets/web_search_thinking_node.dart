import 'package:flutter/material.dart';

import '../models/web_search_trace.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import 'chat_avatar.dart';
import 'web_search_activity_card.dart';

/// Non-interactive web-search trace shown inside the Thinking information tree.
/// It never opens, previews, fetches or exposes a source URL.
class WebSearchThinkingNode extends StatelessWidget {
  const WebSearchThinkingNode.completed({super.key, required this.trace})
    : status = null,
      query = '',
      providers = const <String>[],
      safeMessage = null;

  const WebSearchThinkingNode.activity({
    super.key,
    required WebSearchActivityStatus this.status,
    required this.query,
    required this.providers,
    this.safeMessage,
  }) : trace = null;

  final WebSearchDisplayTrace? trace;
  final WebSearchActivityStatus? status;
  final String query;
  final List<String> providers;
  final String? safeMessage;

  bool get _isSearching => status == WebSearchActivityStatus.searching;

  List<({String title, String host})> get _sources {
    return <({String title, String host})>[
      for (final source in trace?.sources ?? const <WebSearchTraceSource>[])
        (title: source.title, host: source.host),
    ];
  }

  List<String> get _providerFailures {
    final failures = <String>[];
    for (final failure in trace?.failures ?? const <WebSearchTraceFailure>[]) {
      final status = failure.statusCode == null
          ? ''
          : ' (HTTP ${failure.statusCode})';
      failures.add('${failure.provider} · ${failure.safeMessage}$status');
    }
    return failures;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final sources = _sources;
    final providerFailures = _providerFailures;
    final detail = switch (status) {
      WebSearchActivityStatus.awaitingConfirmation => L.pick(
        en: 'Waiting for confirmation',
        zhTW: '等待確認',
        zhCN: '等待确认',
      ),
      WebSearchActivityStatus.searching => L.pick(
        en: 'Searching',
        zhTW: '搜尋中',
        zhCN: '搜索中',
      ),
      WebSearchActivityStatus.completed => L.pick(
        en: 'Search completed · preparing reply',
        zhTW: '搜尋完成 · 正在整理回覆',
        zhCN: '搜索完成 · 正在整理回复',
      ),
      WebSearchActivityStatus.failed =>
        safeMessage?.trim().isNotEmpty == true
            ? safeMessage!.trim()
            : L.pick(en: 'Search not completed', zhTW: '搜尋未完成', zhCN: '搜索未完成'),
      null => '',
    };
    final semanticSources = sources.map((source) => source.host).join(', ');

    return Semantics(
      container: true,
      liveRegion: status != null,
      label: L.pick(en: 'Web Search', zhTW: '網路搜尋', zhCN: '网络搜索'),
      value: <String>[
        if (detail.isNotEmpty) detail,
        if (semanticSources.isNotEmpty) semanticSources,
      ].join(', '),
      child: Container(
        key: const ValueKey<String>('web-search-thinking-node'),
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (_isSearching && !reduceMotion)
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.4,
                      color: YanciTheme.textSecondary,
                    ),
                  )
                else
                  Icon(
                    status == WebSearchActivityStatus.failed
                        ? Icons.error_outline_rounded
                        : status == WebSearchActivityStatus.completed
                        ? Icons.check_circle_outline_rounded
                        : Icons.search_rounded,
                    size: 14,
                    color: YanciTheme.textSecondary,
                  ),
                const SizedBox(width: 7),
                Text(
                  L.pick(en: 'Web Search', zhTW: '網路搜尋', zhCN: '网络搜索'),
                  style: TextStyle(
                    fontSize: 11,
                    color: YanciTheme.textSecondary,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
                if (detail.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.72),
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (status != null && query.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 3),
                child: Text(
                  query.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.35,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.8),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ),
            if (sources.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final source in sources)
                      Padding(
                        key: ValueKey<String>(
                          'web-search-source-label-${source.host}',
                        ),
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '${source.title} · ${source.host}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.35,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.82,
                            ),
                            fontFamily: YanciTheme.fontFamily,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (providerFailures.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final failure in providerFailures)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          failure,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.35,
                            color: Colors.red.shade300.withValues(alpha: 0.86),
                            fontFamily: YanciTheme.fontFamily,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (sources.isEmpty && trace != null && providerFailures.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 3),
                child: Text(
                  trace!.providers.isEmpty
                      ? L.pick(
                          en: 'No safe source labels',
                          zhTW: '沒有可安全顯示的來源',
                          zhCN: '没有可安全显示的来源',
                        )
                      : trace!.providers.join(' + '),
                  style: TextStyle(
                    fontSize: 10,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.72),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Expanded only while the search is active. The completed trace is instead
/// attached to the final message's normally-collapsed Thinking tree.
class WebSearchThinkingActivity extends StatelessWidget {
  const WebSearchThinkingActivity({
    super.key,
    required this.status,
    required this.query,
    required this.providers,
    this.safeMessage,
    this.showAvatar = false,
    this.avatarPath,
  });

  final WebSearchActivityStatus status;
  final String query;
  final List<String> providers;
  final String? safeMessage;
  final bool showAvatar;
  final String? avatarPath;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: YanciTheme.spacingMd,
        right: MediaQuery.sizeOf(context).width * (showAvatar ? 0.15 : 0.2),
        top: YanciTheme.spacingXs,
        bottom: YanciTheme.spacingXs,
      ),
      child: Row(
        key: const ValueKey<String>('web-search-thinking-activity'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (showAvatar) ...[
            ChatAvatar(avatarPath: avatarPath, isUser: false),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'Thinking',
                    style: TextStyle(
                      fontSize: 11,
                      color: YanciTheme.textSecondary,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 26, right: 8),
                  child: WebSearchThinkingNode.activity(
                    status: status,
                    query: query,
                    providers: providers,
                    safeMessage: safeMessage,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
