import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../services/settings_manager.dart';

class KeepAliveGuard {
  final bool cacheOn;
  final bool supports;
  final bool enabled;
  KeepAliveGuard({
    required this.cacheOn,
    required this.supports,
    required this.enabled,
  });
  bool get canEnable => cacheOn && supports;
  String hintText() {
    if (!cacheOn) {
      return L.pick(en: 'Enable prompt caching first', zhTW: '請先開啟上方「提示詞快取」');
    }
    if (!supports) {
      return L.pick(
        en: 'Current model does not support 1h TTL',
        zhTW: '當前模型沒有確認的 1h TTL 支援',
      );
    }
    return '';
  }
}

class ApiAdvancedSettings extends StatefulWidget {
  const ApiAdvancedSettings({super.key});

  @override
  State<ApiAdvancedSettings> createState() => _ApiAdvancedSettingsState();
}

class _ApiAdvancedSettingsState extends State<ApiAdvancedSettings> {
  bool _showCacheSection = false;
  bool _showKeepAliveSection = false;
  bool _showContextSection = false;

  Future<KeepAliveGuard> _loadKeepAliveGuard() async {
    final cacheOn = await MemorySettings.getEnablePromptCaching();
    final enabled = await MemorySettings.getKeepAliveEnabled();
    final provider = await ApiSettings.getApiProvider();
    final model = await ApiSettings.getModelForProvider(provider);
    final isAnthropic = model.contains('anthropic');
    final supports = isAnthropic || provider == 'bedrock';
    return KeepAliveGuard(
      cacheOn: cacheOn,
      supports: supports,
      enabled: enabled,
    );
  }

  Future<void> _handlePromptCachingChanged(bool v) async {
    await MemorySettings.saveEnablePromptCaching(v);
    if (v) {
      await MemorySettings.saveContextLimitEnabled(false);
    } else {
      await MemorySettings.saveKeepAliveEnabled(false);
      await MemorySettings.saveCacheWindowSummaryEnabled(false);
    }
    setState(() {});
  }

  Future<void> _handleContextLimitChanged(bool v, int currentLimit) async {
    await MemorySettings.saveContextLimitEnabled(v);
    if (v) {
      await MemorySettings.saveEnablePromptCaching(false);
      await MemorySettings.saveKeepAliveEnabled(false);
    } else {
      await MemorySettings.saveContextWindowSummaryEnabled(false);
    }
    setState(() {});
  }

  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: YanciTheme.spacingMd,
            vertical: YanciTheme.spacingXs,
          ),
          decoration: BoxDecoration(
            color: YanciTheme.glassInputBg,
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(color: YanciTheme.glassBorder, width: 0.5),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildCollapsibleTitle(
    String title,
    bool isExpanded,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(
              title,
              style: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            AnimatedRotation(
              turns: isExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.expand_more_rounded,
                size: 16,
                color: YanciTheme.textSecondary.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHourPicker({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: YanciTheme.bodySmall.copyWith(
            fontSize: 12,
            color: YanciTheme.textSecondary.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () => onChanged((value - 1) % 24),
          child: Icon(
            Icons.remove_circle_outline,
            size: 20,
            color: YanciTheme.textSecondary.withValues(alpha: 0.4),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${value.toString().padLeft(2, '0')}:00',
            style: TextStyle(
              fontSize: 14,
              fontFamily: YanciTheme.fontFamily,
              fontWeight: FontWeight.w500,
              color: YanciTheme.accent,
            ),
          ),
        ),
        GestureDetector(
          onTap: () => onChanged((value + 1) % 24),
          child: Icon(
            Icons.add_circle_outline,
            size: 20,
            color: YanciTheme.textSecondary.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCollapsibleTitle(
          L.get('settings_cache_title'),
          _showCacheSection,
          () => setState(() => _showCacheSection = !_showCacheSection),
        ),
        if (_showCacheSection) ...[
          const SizedBox(height: YanciTheme.spacingSm),
          _buildGlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            L.get('settings_cache_on'),
                            style: YanciTheme.bodyText.copyWith(fontSize: 13),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            L.get('settings_cache_hint'),
                            style: YanciTheme.bodySmall.copyWith(
                              fontSize: 11,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    FutureBuilder<bool>(
                      future: MemorySettings.getEnablePromptCaching(),
                      builder: (ctx, snap) {
                        final enabled = snap.data ?? false;
                        return Switch(
                          value: enabled,
                          activeThumbColor: YanciTheme.accent,
                          onChanged: _handlePromptCachingChanged,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Divider(
                  height: 1,
                  color: YanciTheme.glassBorder.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                FutureBuilder<List<bool>>(
                  future: Future.wait([
                    MemorySettings.getEnablePromptCaching(),
                    MemorySettings.getCacheWindowSummaryEnabled(),
                  ]),
                  builder: (ctx, snap) {
                    final cacheOn = snap.data?[0] ?? false;
                    final enabled = cacheOn && (snap.data?[1] ?? false);
                    return Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L.pick(
                                  en: 'Dedicated window summary',
                                  zhTW: '專用窗口摘要',
                                ),
                                style: YanciTheme.bodyText.copyWith(
                                  fontSize: 13,
                                  color: cacheOn
                                      ? YanciTheme.textPrimary
                                      : YanciTheme.textSecondary.withValues(
                                          alpha: 0.45,
                                        ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                L.pick(
                                  en: cacheOn
                                      ? 'Injects the latest four summaries into the cacheable prompt for new windows.'
                                      : 'Enable cache hits before turning this on.',
                                  zhTW: cacheOn
                                      ? '新窗口把最新四段摘要注入可緩存提示。'
                                      : '請先開啟緩存命中，才能使用此摘要。',
                                ),
                                style: YanciTheme.bodySmall.copyWith(
                                  fontSize: 11,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: enabled,
                          activeThumbColor: YanciTheme.accent,
                          onChanged: cacheOn
                              ? (v) {
                                  MemorySettings.saveCacheWindowSummaryEnabled(
                                    v,
                                  );
                                  setState(() {});
                                }
                              : null,
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: YanciTheme.spacingLg),

        _buildCollapsibleTitle(
          L.pick(en: 'Auto Cache Renewal', zhTW: '自動延續命中 (Keep-Alive Guard)'),
          _showKeepAliveSection,
          () => setState(() => _showKeepAliveSection = !_showKeepAliveSection),
        ),
        if (_showKeepAliveSection) ...[
          const SizedBox(height: YanciTheme.spacingSm),
          _buildGlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            L.pick(en: 'Enable auto renewal', zhTW: '啟用自動延續'),
                            style: YanciTheme.bodyText.copyWith(fontSize: 14),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            L.pick(
                              en: 'Keeps cache alive by pinging every ~50 min. Incurs extra API cost.',
                              zhTW: '開啟後會增加保持窗口緩存命中的費用，每50分鐘自動延續',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              fontSize: 11,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    FutureBuilder<KeepAliveGuard>(
                      future: _loadKeepAliveGuard(),
                      builder: (ctx, snap) {
                        final guard = snap.data;
                        final enabled = guard?.enabled ?? false;
                        final canEnable = guard?.canEnable ?? false;
                        return Switch(
                          value: enabled,
                          activeThumbColor: YanciTheme.accent,
                          onChanged: canEnable
                              ? (v) async {
                                  await MemorySettings.saveKeepAliveEnabled(v);
                                  if (mounted) setState(() {});
                                }
                              : null,
                        );
                      },
                    ),
                  ],
                ),
                FutureBuilder<KeepAliveGuard>(
                  future: _loadKeepAliveGuard(),
                  builder: (ctx, snap) {
                    final guard = snap.data;
                    final hint = guard == null ? '' : guard.hintText();
                    if (hint.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        hint,
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 11,
                          color: (guard?.canEnable ?? false)
                              ? YanciTheme.textSecondary.withValues(alpha: 0.55)
                              : Colors.orange.withValues(alpha: 0.75),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  L.pick(en: 'Renewal duration (hours)', zhTW: '延續時長（小時）'),
                  style: YanciTheme.bodyText.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 6),
                FutureBuilder<int>(
                  future: MemorySettings.getKeepAliveDurationHours(),
                  builder: (ctx, snap) {
                    final hours = snap.data ?? 2;
                    return Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: hours.toDouble(),
                            min: 1,
                            max: 12,
                            divisions: 11,
                            activeColor: YanciTheme.accent,
                            label: '${hours}h',
                            onChanged: (v) {
                              MemorySettings.saveKeepAliveDurationHours(
                                v.round(),
                              );
                              setState(() {});
                            },
                          ),
                        ),
                        SizedBox(
                          width: 36,
                          child: Text(
                            '${hours}h',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              fontFamily: YanciTheme.fontFamily,
                              fontWeight: FontWeight.w500,
                              color: YanciTheme.accent,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                Text(
                  L.pick(
                    en: 'How long to keep the last message\'s cache alive after leaving chat.',
                    zhTW: '離開聊天後，最後一條消息的緩存延續多久。',
                  ),
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 11,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  L.pick(en: 'Quiet hours (no pings)', zhTW: '安靜時段（不發延續請求）'),
                  style: YanciTheme.bodyText.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 6),
                FutureBuilder<List<int>>(
                  future: Future.wait([
                    MemorySettings.getQuietStartHour(),
                    MemorySettings.getQuietEndHour(),
                  ]),
                  builder: (ctx, snap) {
                    final start = snap.data?[0] ?? 23;
                    final end = snap.data?[1] ?? 7;
                    return Row(
                      children: [
                        _buildHourPicker(
                          label: L.pick(en: 'From', zhTW: '從'),
                          value: start,
                          onChanged: (v) {
                            MemorySettings.saveQuietStartHour(v);
                            setState(() {});
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '→',
                            style: TextStyle(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                        ),
                        _buildHourPicker(
                          label: L.pick(en: 'To', zhTW: '至'),
                          value: end,
                          onChanged: (v) {
                            MemorySettings.saveQuietEndHour(v);
                            setState(() {});
                          },
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: YanciTheme.spacingLg),

        _buildCollapsibleTitle(
          L.get('settings_context_title'),
          _showContextSection,
          () => setState(() => _showContextSection = !_showContextSection),
        ),
        if (_showContextSection) ...[
          const SizedBox(height: YanciTheme.spacingSm),
          _buildGlassCard(
            child: FutureBuilder<List<dynamic>>(
              future: Future.wait([
                MemorySettings.getContextLimitEnabled(),
                MemorySettings.getContextTokenLimit(),
                MemorySettings.getContextWindowSummaryEnabled(),
                MemorySettings.getContextWindowSummaryTriggerTokens(),
                MemorySettings.getEnablePromptCaching(),
              ]),
              builder: (ctx, snap) {
                final storedEnabled = (snap.data?[0] as bool?) ?? false;
                final rawLimit = (snap.data?[1] as int?) ?? 5000;
                final limit = rawLimit < 1000 ? 5000 : rawLimit;
                final summaryEnabled = (snap.data?[2] as bool?) ?? false;
                final summaryTrigger = (snap.data?[3] as int?) ?? 6000;
                final cacheOn = (snap.data?[4] as bool?) ?? false;
                final enabled = storedEnabled && !cacheOn;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            L.get('settings_context_desc'),
                            style: YanciTheme.bodyText.copyWith(fontSize: 13),
                          ),
                        ),
                        Switch(
                          value: enabled,
                          activeThumbColor: YanciTheme.accent,
                          onChanged: cacheOn
                              ? null
                              : (v) => _handleContextLimitChanged(v, limit),
                        ),
                      ],
                    ),
                    if (enabled) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            L.pick(en: 'Max tokens', zhTW: '上限'),
                            style: YanciTheme.bodySmall.copyWith(fontSize: 12),
                          ),
                          const Spacer(),
                          SizedBox(
                            width: 80,
                            child: TextField(
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              style: YanciTheme.bodyText.copyWith(
                                fontSize: 14,
                                color: YanciTheme.accent,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                suffixText: 't',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              controller: TextEditingController(text: '$limit'),
                              onChanged: (v) {
                                final n = int.tryParse(v);
                                if (n != null && n >= 1000) {
                                  MemorySettings.saveContextTokenLimit(n);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        L.pick(
                          en: 'Minimum 1000t. Use the switch above to turn the limit off.',
                          zhTW: '最低 1000t；要關閉限制請直接關上方開關。',
                        ),
                        style: YanciTheme.bodySmall.copyWith(
                          fontSize: 10,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      cacheOn
                          ? (L.pick(
                              en: 'Turn off cache hits before using context send limit.',
                              zhTW: '已開啟緩存命中；需先關閉緩存命中才能使用上下文發送限制。',
                            ))
                          : enabled
                          ? (L.pick(
                              en: '⚠ Context limit may reduce prompt cache hit rate',
                              zhTW: '⚠ 開啟上下文限制可能降低緩存命中率',
                            ))
                          : L.get('settings_context_detail'),
                      style: YanciTheme.bodySmall.copyWith(
                        fontSize: 11,
                        color: enabled || cacheOn
                            ? Colors.orange.withValues(alpha: 0.7)
                            : YanciTheme.textSecondary.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Divider(
                      height: 1,
                      color: YanciTheme.glassBorder.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                L.pick(
                                  en: 'Dynamic window summary',
                                  zhTW: '動態窗口摘要',
                                ),
                                style: YanciTheme.bodyText.copyWith(
                                  fontSize: 13,
                                  color: enabled
                                      ? YanciTheme.textPrimary
                                      : YanciTheme.textSecondary.withValues(
                                          alpha: 0.45,
                                        ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                L.pick(
                                  en: enabled
                                      ? 'For non-cache models. Sends recent summaries through dynamic context.'
                                      : 'Enable context send limit before turning this on.',
                                  zhTW: enabled
                                      ? '給無緩存模型使用，摘要走動態上下文。'
                                      : '請先開啟上下文發送限制，才能使用此摘要。',
                                ),
                                style: YanciTheme.bodySmall.copyWith(
                                  fontSize: 11,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: enabled && summaryEnabled,
                          activeThumbColor: YanciTheme.accent,
                          onChanged: enabled
                              ? (v) {
                                  MemorySettings.saveContextWindowSummaryEnabled(
                                    v,
                                  );
                                  setState(() {});
                                }
                              : null,
                        ),
                      ],
                    ),
                    if (enabled && summaryEnabled) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Text(
                            L.pick(en: 'Summary trigger', zhTW: '摘要觸發'),
                            style: YanciTheme.bodySmall.copyWith(fontSize: 12),
                          ),
                          const Spacer(),
                          SizedBox(
                            width: 86,
                            child: TextField(
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              style: YanciTheme.bodyText.copyWith(
                                fontSize: 14,
                                color: YanciTheme.accent,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                suffixText: 't',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              controller: TextEditingController(
                                text: '$summaryTrigger',
                              ),
                              onChanged: (v) {
                                final n = int.tryParse(v);
                                if (n != null && n >= 1000) {
                                  MemorySettings.saveContextWindowSummaryTriggerTokens(
                                    n,
                                  );
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
