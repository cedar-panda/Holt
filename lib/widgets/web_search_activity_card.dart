import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

enum WebSearchActivityStatus {
  awaitingConfirmation,
  searching,
  completed,
  failed,
}

/// Short-lived status shown while a web-search ToolCall is being authorized or
/// executed. Grounded results use [WebSearchResultCard] instead.
class WebSearchActivityCard extends StatelessWidget {
  const WebSearchActivityCard({
    super.key,
    required this.status,
    required this.query,
    required this.providers,
    this.safeMessage,
  });

  final WebSearchActivityStatus status;
  final String query;
  final List<String> providers;
  final String? safeMessage;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final title = switch (status) {
      WebSearchActivityStatus.awaitingConfirmation => L.pick(
        en: 'Waiting for search confirmation',
        zhTW: '等待確認網路搜尋',
        zhCN: '等待确认网络搜索',
      ),
      WebSearchActivityStatus.searching => L.pick(
        en: 'Searching the public web',
        zhTW: '正在搜尋公開網路',
        zhCN: '正在搜索公开网络',
      ),
      WebSearchActivityStatus.completed => L.pick(
        en: 'Search completed. Preparing reply',
        zhTW: '搜尋完成，正在整理回覆',
        zhCN: '搜索完成，正在整理回复',
      ),
      WebSearchActivityStatus.failed => L.pick(
        en: 'Web search was not completed',
        zhTW: '網路搜尋未完成',
        zhCN: '网络搜索未完成',
      ),
    };
    final providerText = providers.join(' + ');
    final detail = status == WebSearchActivityStatus.failed
        ? (safeMessage?.trim().isNotEmpty ?? false)
              ? safeMessage!.trim()
              : L.pick(
                  en: 'The normal reply was kept.',
                  zhTW: '已保留原本的回覆。',
                  zhCN: '已保留原本的回复。',
                )
        : providerText;

    return Semantics(
      container: true,
      liveRegion: true,
      label: title,
      value: '$query${detail.isEmpty ? '' : ', $detail'}',
      child: Padding(
        padding: EdgeInsets.only(
          left: YanciTheme.spacingMd,
          right: MediaQuery.sizeOf(context).width * 0.2,
          top: YanciTheme.spacingXs,
          bottom: YanciTheme.spacingXs,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: YanciTheme.accent.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(
              color: YanciTheme.accent.withValues(alpha: 0.16),
              width: 0.6,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child:
                    status == WebSearchActivityStatus.searching && !reduceMotion
                    ? SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: YanciTheme.accent,
                        ),
                      )
                    : Icon(
                        status == WebSearchActivityStatus.failed
                            ? Icons.error_outline_rounded
                            : status == WebSearchActivityStatus.searching
                            ? Icons.travel_explore_rounded
                            : status == WebSearchActivityStatus.completed
                            ? Icons.check_circle_outline_rounded
                            : Icons.shield_outlined,
                        size: 16,
                        color: status == WebSearchActivityStatus.failed
                            ? Colors.orange.shade700
                            : YanciTheme.accent,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: YanciTheme.bodySmall.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: YanciTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      query,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: YanciTheme.bodySmall.copyWith(
                        fontSize: 10.5,
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                    if (detail.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 9.5,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
