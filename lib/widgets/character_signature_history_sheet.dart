import 'package:flutter/material.dart';

import '../services/character_signature_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import 'themed_notice.dart';

Future<String?> showCharacterSignatureHistory(
  BuildContext context,
  String characterId,
) async {
  final selected = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CharacterSignatureHistorySheet(characterId: characterId),
  );
  if (selected != null && context.mounted) {
    showThemedPillNotice(
      context,
      L.pick(
        en: 'Displayed signature updated',
        zhTW: '已更改目前顯示的個性簽名',
        zhCN: '已更改当前显示的个性签名',
      ),
      duration: const Duration(milliseconds: 1400),
    );
  }
  return selected;
}

class CharacterSignatureHistorySheet extends StatefulWidget {
  const CharacterSignatureHistorySheet({super.key, required this.characterId});

  final String characterId;

  @override
  State<CharacterSignatureHistorySheet> createState() =>
      _CharacterSignatureHistorySheetState();
}

class _CharacterSignatureHistorySheetState
    extends State<CharacterSignatureHistorySheet> {
  late Future<List<Map<String, dynamic>>> _history;
  int? _savingId;

  @override
  void initState() {
    super.initState();
    _history = CharacterSignatureService.historyForCharacter(
      widget.characterId,
    );
  }

  String _phaseLabel(String phase) =>
      phase == CharacterSignatureService.openingPhase
      ? L.pick(en: 'Opening', zhTW: '開頭', zhCN: '开头')
      : L.pick(en: 'Closing', zhTW: '結束', zhCN: '结束');

  String _modeLabel(String mode) => mode == 'rp'
      ? L.pick(en: 'RP', zhTW: 'RP', zhCN: 'RP')
      : L.pick(en: 'Daily', zhTW: '日常', zhCN: '日常');

  Future<void> _select(Map<String, dynamic> row) async {
    final id = row['id'];
    if (id is! int || _savingId != null) return;
    setState(() => _savingId = id);
    try {
      final signature =
          await CharacterSignatureService.selectDisplayedSignature(
            characterId: widget.characterId,
            signatureId: id,
          );
      if (!mounted) return;
      Navigator.pop(context, signature);
    } catch (_) {
      if (!mounted) return;
      setState(() => _savingId = null);
      showThemedPillNotice(
        context,
        L.pick(
          en: 'Could not change the displayed signature',
          zhTW: '無法更改目前顯示的簽名',
          zhCN: '无法更改当前显示的签名',
        ),
        tone: ThemedNoticeTone.error,
      );
    }
  }

  Future<void> _followLatest() async {
    if (_savingId != null) return;
    setState(() => _savingId = -1);
    try {
      final signature = await CharacterSignatureService.followLatestSignature(
        widget.characterId,
      );
      if (!mounted) return;
      Navigator.pop(context, signature);
    } catch (_) {
      if (!mounted) return;
      setState(() => _savingId = null);
      showThemedPillNotice(
        context,
        L.pick(
          en: 'Could not resume the latest signature',
          zhTW: '無法恢復跟隨最新簽名',
          zhCN: '无法恢复跟随最新签名',
        ),
        tone: ThemedNoticeTone.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        decoration: BoxDecoration(
          color: YanciTheme.surfacePanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: YanciTheme.textSecondary.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    L.pick(
                      en: 'Signature history',
                      zhTW: '個性簽名歷史',
                      zhCN: '个性签名历史',
                    ),
                    style: YanciTheme.headingMedium,
                  ),
                ),
                IconButton(
                  tooltip: L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  L.pick(
                    en: 'Tap a signature to display it on the character card',
                    zhTW: '點擊任一簽名即可設為角色卡目前顯示',
                    zhCN: '点击任一签名即可设为角色卡当前显示',
                  ),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary,
                  ),
                ),
              ),
            ),
            Flexible(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _history,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                  if (rows.isEmpty) return _buildEmptyState();
                  final hasManualSelection = rows.any(
                    (row) => row['is_selected'] == 1,
                  );
                  return Column(
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: hasManualSelection && _savingId == null
                              ? _followLatest
                              : null,
                          icon: _savingId == -1
                              ? SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: YanciTheme.accent,
                                  ),
                                )
                              : const Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 16,
                                ),
                          label: Text(
                            hasManualSelection
                                ? L.pick(
                                    en: 'Follow latest',
                                    zhTW: '跟隨最新',
                                    zhCN: '跟随最新',
                                  )
                                : L.pick(
                                    en: 'Following latest',
                                    zhTW: '正在跟隨最新',
                                    zhCN: '正在跟随最新',
                                  ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, index) =>
                              _buildHistoryRow(rows[index]),
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
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          L.pick(
            en: 'No signature history yet',
            zhTW: '還沒有個性簽名紀錄',
            zhCN: '还没有个性签名记录',
          ),
          textAlign: TextAlign.center,
          style: YanciTheme.bodyText.copyWith(color: YanciTheme.textSecondary),
        ),
      ),
    );
  }

  Widget _buildHistoryRow(Map<String, dynamic> row) {
    final signature = row['signature']?.toString().trim() ?? '';
    final title = row['conversation_title']?.toString().trim();
    final date = row['created_at']?.toString().trim() ?? '';
    final isSelected = row['is_displayed'] == 1;
    final isSaving = _savingId == row['id'];
    final radius = BorderRadius.circular(YanciTheme.radiusMd);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);

    return Semantics(
      button: true,
      selected: isSelected,
      label: isSelected
          ? L.pick(
              en: 'Currently displayed signature',
              zhTW: '目前顯示的個性簽名',
              zhCN: '当前显示的个性签名',
            )
          : L.pick(
              en: 'Set as displayed signature',
              zhTW: '設為目前顯示的個性簽名',
              zhCN: '设为当前显示的个性签名',
            ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: isSaving ? null : () => _select(row),
          child: AnimatedContainer(
            duration: duration,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? YanciTheme.accent.withValues(alpha: 0.08)
                  : YanciTheme.glassInputBg,
              borderRadius: radius,
              border: Border.all(
                color: isSelected
                    ? YanciTheme.accent.withValues(alpha: 0.42)
                    : YanciTheme.glassBorder,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Text(
                            _phaseLabel(row['phase']?.toString() ?? ''),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _modeLabel(row['context_mode']?.toString() ?? ''),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (date.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          date.replaceFirst('T', ' ').split('.').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: YanciTheme.bodySmall.copyWith(
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.65,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    if (isSaving)
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: YanciTheme.accent,
                        ),
                      )
                    else
                      Icon(
                        isSelected
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        size: 18,
                        color: isSelected
                            ? YanciTheme.accent
                            : YanciTheme.textSecondary.withValues(alpha: 0.32),
                      ),
                  ],
                ),
                if (title != null && title.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: YanciTheme.bodySmall.copyWith(
                      color: YanciTheme.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  signature,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: YanciTheme.bodyText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
