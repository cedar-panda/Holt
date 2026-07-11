import 'package:flutter/material.dart';

import '../services/static_token_estimator.dart';
import '../services/locale_strings.dart';
import '../services/x_post_service.dart';
import '../services/x_post_settings.dart';
import '../theme/app_theme.dart';

/// X / 社群發文設定面板（共用）。
/// 原本是 character_card_screen 的私有方法，
/// 入口移到角色列表卡片後抽成共用，兩邊都能開。
Future<void> showXPostPanel(BuildContext context, String charId) async {
  bool enabled = await XPostSettings.isEnabled(charId);
  bool unlimited = await XPostSettings.isUnlimited(charId);
  int limit = await XPostSettings.dailyLimit(charId);
  final used = await XPostSettings.todayCount(charId);
  final handleCtrl = TextEditingController(
    text: await XPostSettings.handle(charId),
  );
  final cidCtrl = TextEditingController(text: await XPostService.clientId());
  bool connected = await XPostService.isConnected(charId);
  bool connecting = false;
  if (!context.mounted) {
    handleCtrl.dispose();
    cidCtrl.dispose();
    return;
  }

  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final canSlide = enabled && !unlimited;
        return Container(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: MediaQuery.viewInsetsOf(ctx).bottom + 28,
          ),
          decoration: BoxDecoration(
            color: YanciTheme.isDark ? const Color(0xFF1A1A22) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Icon(
                    Icons.alternate_email_rounded,
                    color: YanciTheme.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    L.pick(en: 'X / Social posts', zhTW: 'X / 社群發文'),
                    style: YanciTheme.headingMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                L.pick(
                  en: 'Let this character post from their own account when inspiration strikes.',
                  zhTW: '讓這個角色用自己的帳號，在值得的時候起念發文。',
                ),
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                L.pick(en: 'Account connection (OAuth2)', zhTW: '帳號連接（OAuth2）'),
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cidCtrl,
                onChanged: (v) => XPostService.setClientId(v),
                decoration: InputDecoration(
                  labelText: 'X App Client ID',
                  helperText: L.pick(
                    en: 'Create a Native App / Public client at developer.x.com. Set the callback URI to ${XPostService.redirectUri}',
                    zhTW:
                        'developer.x.com 建 App（Native App / Public client），Callback URI 填 ${XPostService.redirectUri}',
                  ),
                  helperMaxLines: 2,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      connected
                          ? '${L.pick(en: 'Connected', zhTW: '已連接')}${handleCtrl.text.isNotEmpty ? ' @${handleCtrl.text}' : ''}'
                          : L.pick(en: 'Not connected', zhTW: '尚未連接'),
                      style: YanciTheme.bodySmall.copyWith(
                        color: connected
                            ? YanciTheme.accent
                            : YanciTheme.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: connecting
                        ? null
                        : () async {
                            if (connected) {
                              await XPostService.disconnect(charId);
                              setSheet(() => connected = false);
                              return;
                            }
                            setSheet(() => connecting = true);
                            XPostService.onConnectResult = (r) async {
                              XPostService.onConnectResult = null;
                              if (r == 'ok') {
                                final h = await XPostService.fetchHandle(
                                  charId,
                                );
                                if (h != null && h.isNotEmpty) {
                                  await XPostSettings.setHandle(charId, h);
                                  handleCtrl.text = h;
                                }
                                if (ctx.mounted) {
                                  setSheet(() {
                                    connected = true;
                                    connecting = false;
                                  });
                                }
                              } else {
                                if (ctx.mounted) {
                                  setSheet(() => connecting = false);
                                  ScaffoldMessenger.of(
                                    ctx,
                                  ).showSnackBar(SnackBar(content: Text(r)));
                                }
                              }
                            };
                            final err = await XPostService.startConnect(charId);
                            if (err != null && ctx.mounted) {
                              XPostService.onConnectResult = null;
                              setSheet(() => connecting = false);
                              ScaffoldMessenger.of(
                                ctx,
                              ).showSnackBar(SnackBar(content: Text(err)));
                            }
                          },
                    child: Text(
                      connecting
                          ? L.pick(
                              en: 'Waiting for authorization…',
                              zhTW: '等待授權…',
                            )
                          : (connected
                                ? L.pick(en: 'Disconnect', zhTW: '斷開')
                                : L.pick(
                                    en: 'Connect X account',
                                    zhTW: '連接 X 帳號',
                                  )),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _switchRow(
                title: L.pick(en: 'Enable X posts', zhTW: '啟用 X 發文'),
                value: enabled,
                onChanged: (v) {
                  XPostSettings.setEnabled(charId, v);
                  setSheet(() => enabled = v);
                  StaticTokenEstimator.showAfterToggle(ctx);
                },
              ),
              _switchRow(
                title: L.pick(en: 'Unlimited inspiration', zhTW: '起念不限制'),
                subtitle: L.pick(
                  en: 'Remove the daily limit; confirmation is still required',
                  zhTW: '解除每日上限（發前確認卡仍在）',
                ),
                value: unlimited,
                enabled: enabled,
                onChanged: (v) {
                  XPostSettings.setUnlimited(charId, v);
                  setSheet(() => unlimited = v);
                },
              ),
              const SizedBox(height: 10),
              Opacity(
                opacity: canSlide ? 1 : 0.35,
                child: IgnorePointer(
                  ignoring: !canSlide,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            L.pick(en: 'Daily limit', zhTW: '每日上限'),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textPrimary,
                            ),
                          ),
                          Text(
                            unlimited
                                ? '∞'
                                : L.pick(en: '$limit/day', zhTW: '$limit 則／天'),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.accent,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: limit.toDouble(),
                        min: 0,
                        max: XPostSettings.maxDailyLimit.toDouble(),
                        divisions: XPostSettings.maxDailyLimit,
                        label: '$limit',
                        activeColor: YanciTheme.accent,
                        onChanged: (v) => setSheet(() => limit = v.round()),
                        onChangeEnd: (v) =>
                            XPostSettings.setDailyLimit(charId, v.round()),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: YanciTheme.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      L.pick(en: 'Posted today', zhTW: '今日已發'),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                    Text(
                      unlimited ? '$used／∞' : '$used／$limit',
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    handleCtrl.dispose();
    cidCtrl.dispose();
  });
}

Widget _switchRow({
  required String title,
  String? subtitle,
  required bool value,
  bool enabled = true,
  required ValueChanged<bool> onChanged,
}) {
  return Opacity(
    opacity: enabled ? 1 : 0.35,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textPrimary,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 11,
                    color: YanciTheme.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: YanciTheme.accent,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    ),
  );
}
