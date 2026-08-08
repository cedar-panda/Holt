import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/locale_strings.dart';
import '../services/system_context_debug.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';

/// 實際 API request 的即時 System Context 診斷。
///
/// 與 Context Debug（壓縮資料）和 Cache Debug（回傳用量）分離；本頁只回答：
/// 本輪 context 被放在哪個 role、user 是否乾淨、快取前綴是否漂移，以及
/// 時間／生物鐘／記憶 marker 是否真的送達。
class SystemContextDebugScreen extends StatefulWidget {
  const SystemContextDebugScreen({super.key});

  @override
  State<SystemContextDebugScreen> createState() =>
      _SystemContextDebugScreenState();
}

class _SystemContextDebugScreenState extends State<SystemContextDebugScreen> {
  bool _revealSensitive = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: ValueListenableBuilder<List<SystemContextDebugSnapshot>>(
                  valueListenable: SystemContextDebug.snapshots,
                  builder: (context, snapshots, _) {
                    if (snapshots.isEmpty) return _buildEmptyState();
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      children: [
                        _buildPrivacyControl(),
                        const SizedBox(height: 12),
                        _buildSnapshot(snapshots.first, latest: true),
                        if (snapshots.length > 1) ...[
                          const SizedBox(height: 20),
                          Text(
                            L.pick(en: 'Recent requests', zhTW: '近期 Request'),
                            style: YanciTheme.bodyText.copyWith(
                              color: YanciTheme.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final snapshot in snapshots.skip(1)) ...[
                            _buildSnapshot(snapshot),
                            const SizedBox(height: 10),
                          ],
                        ],
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

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SizedBox(
        height: 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              'System Context Live',
              textAlign: TextAlign.center,
              style: YanciTheme.headingMedium,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: L.pick(en: 'Back', zhTW: '返回'),
                icon: Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 19,
                  color: YanciTheme.textPrimary,
                ),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: L.pick(en: 'Clear diagnostics', zhTW: '清空診斷'),
                icon: Icon(
                  Icons.delete_sweep_outlined,
                  size: 21,
                  color: YanciTheme.textSecondary,
                ),
                onPressed: SystemContextDebug.clear,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.radar_rounded,
              size: 38,
              color: YanciTheme.accent.withValues(alpha: 0.75),
            ),
            const SizedBox(height: 14),
            Text(
              L.pick(
                en: 'Waiting for the first request',
                zhTW: '等待第一個 Request',
              ),
              textAlign: TextAlign.center,
              style: YanciTheme.headingMedium,
            ),
            const SizedBox(height: 8),
            Text(
              L.pick(
                en: 'Send a chat, image, or call turn, then return here. If a request is assembled while this page is visible, it updates immediately.',
                zhTW: '發送聊天、圖片或通話訊息後回到此頁；若頁面顯示期間有 request 完成組裝，也會立即更新。',
              ),
              textAlign: TextAlign.center,
              style: YanciTheme.bodySmall.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrivacyControl() {
    return _card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            _revealSensitive
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            color: YanciTheme.accent,
            size: 21,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L.pick(en: 'Sensitive preview', zhTW: '敏感內容預覽'),
                  style: YanciTheme.bodyText.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  L.pick(
                    en: 'Off by default. API keys are always redacted.',
                    zhTW: '預設關閉；API Key 無論如何都會遮罩。',
                  ),
                  style: YanciTheme.bodySmall,
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _revealSensitive,
            onChanged: (value) => setState(() => _revealSensitive = value),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapshot(
    SystemContextDebugSnapshot snapshot, {
    bool latest = false,
  }) {
    final statusColor = snapshot.healthy
        ? const Color(0xFF47B881)
        : Colors.orangeAccent;
    return Semantics(
      liveRegion: latest,
      label: snapshot.healthy
          ? L.pick(en: 'System context healthy', zhTW: 'System Context 正常')
          : L.pick(en: 'System context warning', zhTW: 'System Context 有警告'),
      child: _card(
        borderColor: statusColor.withValues(alpha: 0.42),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  snapshot.healthy
                      ? Icons.check_circle_outline_rounded
                      : Icons.warning_amber_rounded,
                  color: statusColor,
                  size: 21,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${snapshot.provider} · ${snapshot.model}',
                        style: YanciTheme.bodyText.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_formatTime(snapshot.capturedAt)} · ${snapshot.cacheChannel}',
                        style: YanciTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: L.pick(en: 'Copy report', zhTW: '複製報告'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _copyReport(snapshot),
                  icon: Icon(
                    Icons.copy_all_outlined,
                    size: 20,
                    color: YanciTheme.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _dataRow(
              L.pick(en: 'Transport', zhTW: '傳輸通道'),
              snapshot.transport.isEmpty ? '—' : snapshot.transport,
            ),
            _dataRow(
              L.pick(en: 'Cache prefix', zhTW: 'Cache 前綴'),
              snapshot.cacheEnabled
                  ? (snapshot.cachePrefixPreserved
                        ? L.pick(en: 'Preserved', zhTW: '保持')
                        : L.pick(en: 'May refresh', zhTW: '可能刷新'))
                  : L.pick(en: 'Cache off / automatic', zhTW: '關閉／自動'),
            ),
            _dataRow(
              'User role',
              snapshot.userRoleClean ? 'CLEAN' : 'CONTAMINATED',
              valueColor: snapshot.userRoleClean
                  ? const Color(0xFF47B881)
                  : Colors.redAccent,
            ),
            _dataRow(
              L.pick(en: 'Stable / Live', zhTW: '穩定／即時'),
              '${snapshot.stableChars} / ${snapshot.liveChars} chars',
            ),
            const SizedBox(height: 10),
            Text(
              L.pick(en: 'Role map', zhTW: 'Role 分佈'),
              style: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: snapshot.roles
                  .asMap()
                  .entries
                  .map(
                    (entry) => _roleChip(
                      entry.value,
                      isLatestUser: entry.key == snapshot.latestUserIndex,
                      isBreakpoint: entry.key == snapshot.cacheBreakpointIndex,
                    ),
                  )
                  .toList(growable: false),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _markerChip('TIME', snapshot.hasTime),
                _markerChip('BIO', snapshot.hasBioClock),
                _markerChip('MEMORY', snapshot.hasMemory),
                _markerChip(
                  snapshot.stablePrefixDrifted ? 'PREFIX DRIFT' : 'PREFIX',
                  !snapshot.stablePrefixDrifted,
                ),
              ],
            ),
            if (snapshot.fallbackReason.isNotEmpty) ...[
              const SizedBox(height: 10),
              _notice(snapshot.fallbackReason, Colors.orangeAccent),
            ],
            if (snapshot.warnings.isNotEmpty) ...[
              const SizedBox(height: 10),
              _notice(snapshot.warnings.join('\n'), Colors.redAccent),
            ],
            const SizedBox(height: 10),
            Material(
              color: Colors.transparent,
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  L.pick(en: 'Context preview', zhTW: 'Context 預覽'),
                  style: YanciTheme.bodyText.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                children: [
                  _previewBlock(
                    L.pick(en: 'Stable prefix', zhTW: '穩定前綴'),
                    _revealSensitive
                        ? snapshot.stablePreview
                        : snapshot.maskedStablePreview,
                  ),
                  const SizedBox(height: 8),
                  _previewBlock(
                    'Live State',
                    _revealSensitive
                        ? snapshot.livePreview
                        : snapshot.maskedLivePreview,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dataRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 108, child: Text(label, style: YanciTheme.bodySmall)),
          Expanded(
            child: Text(
              value,
              style: YanciTheme.bodyText.copyWith(
                fontSize: 12.5,
                color: valueColor ?? YanciTheme.textPrimary,
                fontWeight: valueColor == null
                    ? FontWeight.w400
                    : FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roleChip(
    String role, {
    required bool isLatestUser,
    required bool isBreakpoint,
  }) {
    final suffix = <String>[
      if (isBreakpoint) '⚡',
      if (isLatestUser) 'LATEST',
    ].join(' ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: (isLatestUser ? YanciTheme.accent : YanciTheme.glassWhite)
            .withValues(alpha: isLatestUser ? 0.18 : 0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isLatestUser
              ? YanciTheme.accent.withValues(alpha: 0.45)
              : YanciTheme.glassBorder,
        ),
      ),
      child: Text(
        '$role${suffix.isEmpty ? '' : ' · $suffix'}',
        style: YanciTheme.bodySmall.copyWith(fontSize: 11),
      ),
    );
  }

  Widget _markerChip(String label, bool present) {
    final color = present ? const Color(0xFF47B881) : YanciTheme.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          present ? Icons.check_circle_rounded : Icons.remove_circle_outline,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: YanciTheme.bodySmall.copyWith(fontSize: 10.5, color: color),
        ),
      ],
    );
  }

  Widget _notice(String text, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        text,
        style: YanciTheme.bodySmall.copyWith(color: color, height: 1.4),
      ),
    );
  }

  Widget _previewBlock(String label, String content) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: YanciTheme.glassWhite.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: YanciTheme.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          SelectableText(
            content,
            style: YanciTheme.bodyText.copyWith(fontSize: 11.5, height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child, Color? borderColor}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: YanciTheme.surfacePanel,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        border: Border.all(
          color: borderColor ?? YanciTheme.glassBorder,
          width: 0.8,
        ),
      ),
      child: child,
    );
  }

  Future<void> _copyReport(SystemContextDebugSnapshot snapshot) async {
    await Clipboard.setData(
      ClipboardData(text: snapshot.report(revealSensitive: _revealSensitive)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L.pick(en: 'Report copied', zhTW: '報告已複製')),
      ),
    );
  }

  static String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}
