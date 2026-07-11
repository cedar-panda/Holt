import 'dart:convert';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/settings/user_settings.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import 'context_debug_screen.dart';
import '../services/bio_clock_service.dart';
import '../services/cache_debug_log.dart';

class DeveloperDiagnosticsScreen extends StatefulWidget {
  const DeveloperDiagnosticsScreen({super.key});

  @override
  State<DeveloperDiagnosticsScreen> createState() =>
      _DeveloperDiagnosticsScreenState();
}

class _DeveloperDiagnosticsScreenState
    extends State<DeveloperDiagnosticsScreen> {
  void _showBioClockDebug(String characterId) async {
    final json = await BioClockService.exportJson(characterId);
    final data = const JsonDecoder().convert(json) as Map<String, dynamic>;
    final habits = data['habits'] as List<dynamic>? ?? [];
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          L.pick(en: '🕐 Bio Clock (DEBUG)', zhTW: '🕐 生物鐘（DEBUG）'),
          style: YanciTheme.headingMedium,
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: habits.isEmpty
              ? Text(
                  L.pick(en: 'No habit records', zhTW: '沒有習慣記錄'),
                  style: YanciTheme.bodyText,
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: habits.length,
                  itemBuilder: (_, i) {
                    final h = habits[i] as Map<String, dynamic>;
                    final hour = (h['hour'] as int).toString().padLeft(2, '0');
                    final min = (h['minute'] as int? ?? 0).toString().padLeft(
                      2,
                      '0',
                    );
                    final kw = (h['keywords'] as List<dynamic>).join(', ');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '#${h['id']}  $hour:$min  ${h['content']}\n    ${L.pick(en: 'Keywords', zhTW: '關鍵詞')}：$kw',
                        style: YanciTheme.bodyText.copyWith(fontSize: 13),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.pick(en: 'Close', zhTW: '關閉'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtT(Object? v) {
    final t = v is int ? v : 0;
    return t >= 1000 ? '${(t / 1000).toStringAsFixed(1)}k' : '$t';
  }

  void _showCacheDebug() {
    final entries = CacheDebugLog.entries;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          L.pick(en: '⚡ Cache Fingerprint (DEBUG)', zhTW: '⚡ 緩存指紋（DEBUG）'),
          style: YanciTheme.headingMedium,
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: entries.isEmpty
              ? Text(
                  L.pick(
                    en: 'No request records yet.\nSend a message or two and come back.',
                    zhTW: '還沒有請求記錄。\n發一兩條消息再回來看。',
                  ),
                  style: YanciTheme.bodyText,
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length + 1,
                  itemBuilder: (_, i) {
                    if (i == entries.length) {
                      // 尾部判讀說明
                      return Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          L.pick(
                            en: 'Reading:\n⚠️ Fingerprint changed = static-prefix drift (segments listed below the row)\nUnchanged but ⚡0 = expired TTL or route drift\nGray ⚙ rows are internal requests (naming/summary), excluded from comparison',
                            zhTW:
                                '判讀：\n⚠️ 指紋變 = 靜態前綴漂移（行下方會列出具體變更段）\n指紋沒變但 ⚡0 = TTL 過期或路由漂移\n灰色 ⚙ 行 = 命名/摘要等內部請求，已排除在比較外',
                          ),
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 11,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      );
                    }
                    final e = entries[i];
                    final hash = (e['hash'] ?? '').toString();
                    final hashShort = hash.length >= 6
                        ? hash.substring(0, 6)
                        : (hash.isEmpty ? '——' : hash);
                    final isInternal = e['internal'] == true;

                    // ═══ 內部請求（命名/摘要等）：灰色縮進，不參與比較 ═══
                    if (isInternal) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '${e['at']}  ⚙ 內部請求（命名/摘要等，不影響主緩存）\n'
                          '        入 ${_fmtT(e['prompt_t'])}t',
                          style: YanciTheme.bodyText.copyWith(
                            fontSize: 11.5,
                            height: 1.35,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                      );
                    }

                    // entries[0] 最新；跟「上一條非內部主請求」比（內部插隊不誤報）
                    Map<String, Object?>? prevMain;
                    for (var j = i + 1; j < entries.length; j++) {
                      if (entries[j]['internal'] != true) {
                        prevMain = entries[j];
                        break;
                      }
                    }
                    final prev = (prevMain?['hash'] ?? '').toString();
                    final drifted =
                        prevMain != null && prev.isNotEmpty && prev != hash;

                    // ═══ 漂移時分段 diff：具體標出哪段變了 ═══
                    var diffNote = '';
                    if (drifted) {
                      final curSegs = (e['segs'] as List?)?.cast<String>();
                      final oldSegs = (prevMain['segs'] as List?)
                          ?.cast<String>();
                      if (curSegs != null &&
                          oldSegs != null &&
                          curSegs.isNotEmpty) {
                        final oldSet = oldSegs.toSet();
                        final newSet = curSegs.toSet();
                        final changed = curSegs
                            .where((s) => !oldSet.contains(s))
                            .map((s) => s.split('|').last)
                            .take(3)
                            .toList();
                        final removed = oldSegs
                            .where((s) => !newSet.contains(s))
                            .map((s) => s.split('|').last)
                            .take(3)
                            .toList();
                        if (changed.isNotEmpty) {
                          diffNote += '\n    ↳ 新/變段：${changed.join('、')}';
                        }
                        if (removed.isNotEmpty) {
                          diffNote += '\n    ↳ 消失段：${removed.join('、')}';
                        }
                      }
                    }

                    final read = e['read'] as int? ?? 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '${e['at']}  指紋 $hashShort${drifted ? '  ⚠️變了' : ''}\n'
                        '    入 ${_fmtT(e['prompt_t'])}t · ⚡讀 ${_fmtT(e['read'])} · 📦寫 ${_fmtT(e['write'])}\n'
                        '    靜態 ${_fmtT(e['static_t'])} · 動態 ${_fmtT(e['dynamic_t'])}'
                        '$diffNote',
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 12.5,
                          height: 1.35,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: drifted
                              ? Colors.redAccent
                              : (read > 0
                                    ? YanciTheme.textPrimary
                                    : YanciTheme.textPrimary.withValues(
                                        alpha: 0.6,
                                      )),
                        ),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              CacheDebugLog.clear();
              Navigator.pop(ctx);
            },
            child: Text(
              L.pick(en: 'Clear', zhTW: '清空'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.pick(en: 'Close', zhTW: '關閉'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlassCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YanciTheme.surfacePanel,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(
          color: YanciTheme.accent.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: YanciTheme.spacingSm,
                  vertical: YanciTheme.spacingXs,
                ),
                child: SizedBox(
                  height: 48,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: Text(
                          L.pick(en: 'Diagnostics', zhTW: '開發者診斷'),
                          textAlign: TextAlign.center,
                          style: YanciTheme.headingMedium,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: Icon(
                            Icons.arrow_back_ios_rounded,
                            size: 20,
                            color: YanciTheme.textPrimary,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(YanciTheme.spacingMd),
                  children: [
                    GestureDetector(
                      onTap: () async {
                        final navigator = Navigator.of(context);
                        final charId =
                            await UserSettings.getActiveCharacterId();
                        if (!mounted) return;
                        navigator.push(
                          MaterialPageRoute(
                            builder: (_) =>
                                ContextDebugScreen(characterId: charId),
                          ),
                        );
                      },
                      child: _buildGlassCard(
                        child: Row(
                          children: [
                            Icon(
                              Icons.bug_report,
                              size: 20,
                              color: YanciTheme.accent,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Context Debug',
                              style: YanciTheme.bodyText.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.chevron_right,
                              size: 20,
                              color: YanciTheme.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () async {
                        final charId =
                            await UserSettings.getActiveCharacterId();
                        if (!mounted) return;
                        _showBioClockDebug(charId);
                      },
                      child: _buildGlassCard(
                        child: Row(
                          children: [
                            Icon(
                              Icons.schedule,
                              size: 20,
                              color: YanciTheme.accent,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'BioClock Debug',
                              style: YanciTheme.bodyText.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.chevron_right,
                              size: 20,
                              color: YanciTheme.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: _showCacheDebug,
                      child: _buildGlassCard(
                        child: Row(
                          children: [
                            Icon(
                              Icons.bolt_rounded,
                              size: 20,
                              color: YanciTheme.accent,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Cache Debug',
                              style: YanciTheme.bodyText.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.chevron_right,
                              size: 20,
                              color: YanciTheme.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
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
