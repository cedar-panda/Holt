import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_error_log_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';

class ErrorDiagnosticsScreen extends StatefulWidget {
  const ErrorDiagnosticsScreen({super.key});

  @override
  State<ErrorDiagnosticsScreen> createState() => _ErrorDiagnosticsScreenState();
}

class _ErrorDiagnosticsScreenState extends State<ErrorDiagnosticsScreen> {
  List<Map<String, Object?>> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await AppErrorLogService.latest();
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _clear() async {
    await AppErrorLogService.clear();
    if (mounted) setState(() => _entries = const []);
  }

  Future<void> _export() async {
    final file = await AppErrorLogService.exportLogFile();
    if (!mounted) return;
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: 'text/plain')],
        fileNameOverrides: <String>[file.uri.pathSegments.last],
        title: L.pick(
          en: 'Share Holt error log',
          zhTW: '分享 Holt 報錯日誌',
          zhCN: '分享 Holt 报错日志',
        ),
        sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 20,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      L.pick(en: 'Error records', zhTW: '報錯記錄', zhCN: '报错记录'),
                      textAlign: TextAlign.center,
                      style: YanciTheme.headingMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: L.pick(en: 'Export', zhTW: '匯出', zhCN: '导出'),
                    onPressed: _export,
                    icon: const Icon(Icons.ios_share_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: L.pick(en: 'Clear', zhTW: '清除', zhCN: '清除'),
                    onPressed: _entries.isEmpty ? null : _clear,
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  ),
                ],
              ),
              Expanded(
                child: _entries.isEmpty
                    ? Center(
                        child: Text(
                          L.pick(
                            en: 'No errors recorded',
                            zhTW: '目前沒有報錯記錄',
                            zhCN: '目前没有报错记录',
                          ),
                          style: YanciTheme.bodyText.copyWith(
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: _entries.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          final summary = '${entry['summary'] ?? ''}';
                          return ExpansionTile(
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              8,
                              0,
                              8,
                              12,
                            ),
                            title: Text(summary),
                            subtitle: Text(
                              '${entry['source'] ?? ''} · ${entry['trigger'] ?? ''} · ${entry['created_at'] ?? ''}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: YanciTheme.bodySmall.copyWith(
                                color: YanciTheme.textSecondary,
                              ),
                            ),
                            children: [
                              SelectableText(
                                [
                                  'provider=${entry['provider'] ?? ''}',
                                  'model=${entry['model'] ?? ''}',
                                  'status=${entry['status_code'] ?? ''}',
                                  'raw=${entry['raw_log'] ?? ''}',
                                ].join('\n'),
                                style: YanciTheme.bodySmall.copyWith(
                                  fontFamily: 'monospace',
                                  height: 1.4,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
