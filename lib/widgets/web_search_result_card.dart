import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/locale_strings.dart';
import '../services/web_search_service.dart';
import '../theme/app_theme.dart';

/// Native, non-Markdown renderer for one logical web-search run.
///
/// Provider answers are rendered as plain selectable text. Only structured,
/// revalidated citation URLs are tappable, so webpage text can never smuggle a
/// custom-scheme link or an App tool tag into the normal chat bubble parser.
class WebSearchResultCard extends StatelessWidget {
  const WebSearchResultCard({
    super.key,
    required this.result,
    this.initiallyExpanded = true,
  });

  final WebSearchBatchResult result;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: YanciTheme.spacingMd,
        right: MediaQuery.sizeOf(context).width * 0.12,
        top: YanciTheme.spacingXs,
        bottom: YanciTheme.spacingXs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < result.outcomes.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 8),
            _ProviderResultCard(
              outcome: result.outcomes[i],
              initiallyExpanded: initiallyExpanded,
            ),
          ],
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              L.pick(
                en: 'Shown for this session only; search content is not written to chat history or prompt cache.',
                zhTW: '僅在本次工作階段顯示；搜尋內容不寫入聊天紀錄或提示詞快取。',
                zhCN: '仅在本次会话显示；搜索内容不写入聊天记录或提示词缓存。',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 9.5,
                color: YanciTheme.textSecondary.withValues(alpha: 0.64),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A provider result owns its complete visual surface. In dual mode Gemini and
/// OpenRouter are deliberately not placed in a shared card or common result
/// header, so a Grounded Result is never visually interspersed with another
/// provider's content.
class _ProviderResultCard extends StatefulWidget {
  const _ProviderResultCard({
    required this.outcome,
    required this.initiallyExpanded,
  });

  final WebSearchProviderOutcome outcome;
  final bool initiallyExpanded;

  @override
  State<_ProviderResultCard> createState() => _ProviderResultCardState();
}

class _ProviderResultCardState extends State<_ProviderResultCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final outcome = widget.outcome;
    final provider = _providerLabel(outcome.provider);
    final failed = outcome.failure != null;
    final sourceCount = outcome.result?.sources.length ?? 0;
    final title = L.pick(
      en: '$provider web result',
      zhTW: '$provider · 網路搜尋結果',
      zhCN: '$provider · 网络搜索结果',
    );
    final summary = failed
        ? L.pick(en: 'Search failed', zhTW: '搜尋失敗', zhCN: '搜索失败')
        : L.pick(
            en: '$sourceCount sources',
            zhTW: '$sourceCount 個來源',
            zhCN: '$sourceCount 个来源',
          );
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return DecoratedBox(
      key: ValueKey<String>(
        'web_search_provider_card_${outcome.provider.name}',
      ),
      decoration: BoxDecoration(
        color: YanciTheme.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: 0.16),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            button: true,
            expanded: _expanded,
            label: title,
            value: summary,
            child: InkWell(
              key: ValueKey<String>(
                'web_search_result_toggle_${outcome.provider.name}',
              ),
              borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
              onTap: () => setState(() => _expanded = !_expanded),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        failed
                            ? Icons.warning_amber_rounded
                            : Icons.public_rounded,
                        size: 17,
                        color: failed
                            ? Colors.orange.shade700
                            : YanciTheme.accent,
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
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: YanciTheme.textPrimary,
                              ),
                            ),
                            Text(
                              summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: YanciTheme.bodySmall.copyWith(
                                fontSize: 10,
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.72,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 20,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Divider(
                            height: 1,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _ProviderOutcomeView(outcome: outcome),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderOutcomeView extends StatelessWidget {
  const _ProviderOutcomeView({required this.outcome});

  final WebSearchProviderOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final result = outcome.result;
    final failure = outcome.failure;
    return Semantics(
      container: true,
      label: _providerLabel(outcome.provider),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (result != null) ...<Widget>[
            SelectableText(
              result.text,
              key: ValueKey<String>(
                'web_search_answer_${outcome.provider.name}',
              ),
              style: YanciTheme.bodyText.copyWith(
                fontSize: 12,
                height: 1.5,
                color: YanciTheme.textPrimary,
              ),
            ),
            if (result.attribution case final attribution?) ...<Widget>[
              const SizedBox(height: 10),
              Semantics(
                container: true,
                label: L.pick(
                  en: 'Required Google Search suggestions',
                  zhTW: 'Google 規定顯示的搜尋建議',
                  zhCN: 'Google 规定显示的搜索建议',
                ),
                child: HtmlWidget(
                  attribution.renderedContent,
                  key: const ValueKey<String>('gemini_search_attribution'),
                  enableCaching: false,
                  factoryBuilder: _AttributionWidgetFactory.new,
                  textStyle: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textPrimary,
                    fontSize: 11,
                  ),
                  onTapUrl: _openGoogleSuggestion,
                ),
              ),
            ],
            if (result.sources.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                L.pick(en: 'Sources', zhTW: '來源', zhCN: '来源'),
                style: YanciTheme.bodySmall.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: YanciTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              for (final source in result.sources)
                _SourceRow(
                  source: source,
                  preserveLabel: outcome.provider == WebSearchProviderId.gemini,
                ),
            ],
          ] else if (failure != null)
            Text(
              failure.safeMessage,
              key: ValueKey<String>(
                'web_search_failure_${outcome.provider.name}',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 11,
                height: 1.45,
                color: YanciTheme.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, this.preserveLabel = false});

  final WebSearchSource source;
  final bool preserveLabel;

  @override
  Widget build(BuildContext context) {
    final uri = safeWebSearchSourceUri(source.url);
    if (uri == null) return const SizedBox.shrink();
    final label = preserveLabel
        ? source.title
        : (source.title.trim().isEmpty ? uri.host : source.title.trim());
    return Semantics(
      button: true,
      link: true,
      label: '$label, ${uri.host}',
      child: InkWell(
        key: ValueKey<String>('web_search_source_${source.url}'),
        borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 11,
                          color: YanciTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        uri.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 9.5,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.68,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.open_in_new_rounded,
                  size: 15,
                  color: YanciTheme.textSecondary.withValues(alpha: 0.65),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> _openGoogleSuggestion(String raw) async {
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return true;
  }
  final host = uri.host.toLowerCase();
  if (host != 'google.com' && !host.endsWith('.google.com')) return true;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
  return true;
}

/// Search Suggestions may contain provider-supplied HTML/CSS. Keep rendering
/// isolated and prevent `<img>` or CSS backgrounds from making surprise
/// network/file requests; self-contained data images remain available for the
/// provider's required visual treatment.
class _AttributionWidgetFactory extends WidgetFactory {
  @override
  Widget? buildImageWidget(BuildTree tree, ImageSource source) {
    if (!source.url.startsWith('data:image/')) return null;
    return super.buildImageWidget(tree, source);
  }

  @override
  DecorationImage? buildDecorationImage(
    BuildTree tree,
    String? url, {
    AlignmentGeometry alignment = Alignment.topLeft,
    BoxFit fit = BoxFit.scaleDown,
    ImageRepeat repeat = ImageRepeat.noRepeat,
  }) {
    if (url == null || !url.startsWith('data:image/')) return null;
    return super.buildDecorationImage(
      tree,
      url,
      alignment: alignment,
      fit: fit,
      repeat: repeat,
    );
  }
}

String _providerLabel(WebSearchProviderId provider) => switch (provider) {
  WebSearchProviderId.openRouter => 'OpenRouter',
  WebSearchProviderId.gemini => 'Gemini',
};
