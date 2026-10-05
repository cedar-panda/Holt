import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_diagnostic_event.dart';
import '../services/api_error_localizer.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class ChatDiagnosticCard extends StatefulWidget {
  const ChatDiagnosticCard({
    super.key,
    required this.event,
    required this.onRetry,
  });

  final ChatDiagnosticEvent event;
  final Future<void> Function() onRetry;

  @override
  State<ChatDiagnosticCard> createState() => _ChatDiagnosticCardState();
}

class _ChatDiagnosticCardState extends State<ChatDiagnosticCard> {
  bool _expanded = false;
  bool _retrying = false;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  ApiErrorDiagnosis get _diagnosis => ApiErrorLocalizer.diagnose(
    widget.event.rawLog.isEmpty
        ? 'HTTP ${widget.event.statusCode ?? ''}'
        : widget.event.rawLog,
  );

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _copy() async {
    final meta = <String>[
      if (widget.event.provider.isNotEmpty) 'provider=${widget.event.provider}',
      if (widget.event.model.isNotEmpty) 'model=${widget.event.model}',
      if (widget.event.statusCode != null) 'status=${widget.event.statusCode}',
      'time=${widget.event.createdAt.toIso8601String()}',
    ];
    final log = <String>[
      meta.join(' '),
      widget.event.rawLog,
    ].where((line) => line.trim().isNotEmpty).join('\n');
    await Clipboard.setData(ClipboardData(text: log));
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Color.lerp(
      const Color(0xFFCB5C64),
      YanciTheme.accent,
      .22,
    )!;
    final surface = Color.alphaBlend(
      errorColor.withValues(alpha: YanciTheme.isDark ? .10 : .055),
      Theme.of(context).colorScheme.surface,
    );
    final diagnosis = _diagnosis;
    final summary =
        widget.event.provider.isNotEmpty && diagnosis.provider == null
        ? '${widget.event.provider}${L.locale == 'en' ? ': ' : '：'}${diagnosis.summary}'
        : diagnosis.summary;

    return Semantics(
      container: true,
      liveRegion: true,
      label: summary,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 30, 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: errorColor.withValues(alpha: .30),
              width: .8,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 17,
                        color: errorColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        summary,
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 13,
                          height: 1.45,
                          color: YanciTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  children: [
                    TextButton.icon(
                      onPressed: _retrying ? null : _retry,
                      icon: _retrying
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: errorColor,
                              ),
                            )
                          : const Icon(Icons.refresh_rounded, size: 17),
                      label: Text(
                        L.pick(en: 'Try again', zhTW: '重新落筆', zhCN: '重新落笔'),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: errorColor,
                        minimumSize: const Size(44, 44),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _copy,
                      icon: Icon(
                        _copied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 16,
                      ),
                      label: Text(
                        _copied
                            ? L.pick(en: 'Copied', zhTW: '已複製', zhCN: '已复制')
                            : L.pick(
                                en: 'Copy raw log',
                                zhTW: '複製原始日誌',
                                zhCN: '复制原始日志',
                              ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: YanciTheme.textSecondary,
                        minimumSize: const Size(44, 44),
                      ),
                    ),
                  ],
                ),
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            L.pick(
                              en: 'Technical details',
                              zhTW: '技術詳情',
                              zhCN: '技术详情',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: .74,
                              ),
                            ),
                          ),
                        ),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: .58,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_expanded) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    widget.event.rawLog,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.45,
                      color: YanciTheme.textSecondary.withValues(alpha: .82),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
