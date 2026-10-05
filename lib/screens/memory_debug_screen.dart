import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/locale_strings.dart';
import '../services/memory_debug_log.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';

class MemoryDebugScreen extends StatelessWidget {
  const MemoryDebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(
                        Icons.arrow_back_ios_new,
                        size: 18,
                        color: YanciTheme.textPrimary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Memory Debug',
                        textAlign: TextAlign.center,
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: L.pick(en: 'Clear', zhTW: '清除', zhCN: '清除'),
                      onPressed: MemoryDebugLog.clear,
                      icon: Icon(
                        Icons.delete_sweep_outlined,
                        size: 20,
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ValueListenableBuilder<List<MemoryDebugEvent>>(
                  valueListenable: MemoryDebugLog.events,
                  builder: (context, events, _) {
                    if (events.isEmpty) {
                      return Center(
                        child: Text(
                          L.pick(
                            en: 'Waiting for memory activity',
                            zhTW: '等待記憶活動',
                            zhCN: '等待记忆活动',
                          ),
                          style: YanciTheme.bodySmall,
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                      itemCount: events.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final event = events[index];
                        return Semantics(
                          button: true,
                          label: '${event.stage}, ${event.scope}',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () async {
                              await Clipboard.setData(
                                ClipboardData(text: event.report()),
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    L.pick(
                                      en: 'Debug entry copied',
                                      zhTW: '已複製 Debug 記錄',
                                      zhCN: '已复制 Debug 记录',
                                    ),
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: YanciTheme.surfacePanel.withValues(
                                  alpha: 0.72,
                                ),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.10,
                                  ),
                                ),
                              ),
                              child: Text(
                                event.report(),
                                style: YanciTheme.bodySmall.copyWith(
                                  height: 1.45,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ),
                        );
                      },
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
