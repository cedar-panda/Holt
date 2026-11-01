import 'package:flutter/material.dart';

import '../../screens/cost_context_screen.dart';
import '../../services/locale_strings.dart';
import '../../services/mood_glow_service.dart';
import '../../services/reply_notification_service.dart';
import '../../services/settings/user_settings.dart';
import '../../theme/app_theme.dart';
import 'holt_sidebar_shell.dart';
import 'sidebar_visual_tokens.dart';

/// UI_SLOT: sidebar_feature_modules
///
/// Navigation-only shell. The four functional groups and their switches live
/// in CostContextScreen so there is one persistence path instead of duplicate
/// controls with drifting state.
class SidebarFeatureSettings extends StatefulWidget {
  const SidebarFeatureSettings({super.key});

  @override
  State<SidebarFeatureSettings> createState() => _SidebarFeatureSettingsState();
}

class _SidebarFeatureSettingsState extends State<SidebarFeatureSettings> {
  bool? _showAvatars;
  bool _savingAvatars = false;
  bool? _replyNotifications;
  bool _savingReplyNotifications = false;
  MoodGlowScope? _moodScope;
  MoodGlowBlend? _moodBlend;

  @override
  void initState() {
    super.initState();
    _loadAvatars();
  }

  Future<void> _loadAvatars() async {
    final results = await Future.wait<Object>([
      UserSettings.getShowChatAvatar(),
      MoodGlowService.getScope(),
      ReplyNotificationService.isEnabled(),
      MoodGlowService.getBlend(),
    ]);
    if (mounted) {
      setState(() {
        _showAvatars = results[0] as bool;
        _moodScope = results[1] as MoodGlowScope;
        _replyNotifications = results[2] as bool;
        _moodBlend = results[3] as MoodGlowBlend;
      });
    }
  }

  Future<void> _setReplyNotifications(bool value) async {
    final previous = _replyNotifications;
    setState(() {
      _replyNotifications = value;
      _savingReplyNotifications = true;
    });
    try {
      await ReplyNotificationService.setEnabled(value);
    } catch (_) {
      if (mounted) setState(() => _replyNotifications = previous);
    } finally {
      if (mounted) setState(() => _savingReplyNotifications = false);
    }
  }

  Future<void> _setMoodScope(MoodGlowScope scope) async {
    setState(() => _moodScope = scope);
    await MoodGlowService.saveScope(scope);
    // 關掉時立刻收起目前窗口的光；重新開啟時下次進窗口再載入。
    if (scope == MoodGlowScope.off) MoodGlowService.activeColor.value = null;
  }

  /// 「頭像顯示」底下的子項：心情流光範圍（關／日常／RP／全部）。
  /// 關閉＝聊天頭像與通話流光都不顯示，模型也不會被要求輸出顏色。
  Widget _moodGlowRow() {
    final current = _moodScope;
    String label(MoodGlowScope scope) => switch (scope) {
      MoodGlowScope.off => L.pick(en: 'Off', zhTW: '關', zhCN: '关'),
      MoodGlowScope.daily => L.pick(en: 'Daily', zhTW: '日常', zhCN: '日常'),
      MoodGlowScope.rp => 'RP',
      MoodGlowScope.all => L.pick(en: 'All', zhTW: '全部', zhCN: '全部'),
    };
    return _moodSubRow(
      key: const ValueKey('sidebar-mood-glow-scope'),
      title: L.pick(en: 'Mood glow', zhTW: '心情流光', zhCN: '心情流光'),
      pills: [
        for (final scope in MoodGlowScope.values)
          _moodPill(
            key: ValueKey('mood-glow-scope-${scope.storageValue}'),
            text: label(scope),
            semantics:
                '${L.pick(en: 'Mood glow', zhTW: '心情流光', zhCN: '心情流光')} ${label(scope)}',
            selected: current == scope,
            onTap: current == null || current == scope
                ? null
                : () => _setMoodScope(scope),
          ),
      ],
    );
  }

  /// 心情流光的顏色呈現：融入主題色／獨立流光（預設）。範圍為「關」時不顯示。
  Widget _moodBlendRow() {
    final current = _moodBlend;
    String label(MoodGlowBlend mode) => switch (mode) {
      MoodGlowBlend.theme => L.pick(
        en: 'Theme',
        zhTW: '融入主題色',
        zhCN: '融入主题色',
      ),
      MoodGlowBlend.independent => L.pick(
        en: 'Own color',
        zhTW: '獨立流光',
        zhCN: '独立流光',
      ),
    };
    final title = L.pick(en: 'Glow color', zhTW: '流光顏色', zhCN: '流光颜色');
    return _moodSubRow(
      key: const ValueKey('sidebar-mood-glow-blend'),
      title: title,
      pills: [
        for (final mode in MoodGlowBlend.values)
          _moodPill(
            key: ValueKey('mood-glow-blend-${mode.storageValue}'),
            text: label(mode),
            semantics: '$title ${label(mode)}',
            selected: current == mode,
            onTap: current == null || current == mode
                ? null
                : () => _setMoodBlend(mode),
          ),
      ],
    );
  }

  Future<void> _setMoodBlend(MoodGlowBlend mode) async {
    setState(() => _moodBlend = mode);
    await MoodGlowService.saveBlend(mode);
  }

  Widget _moodSubRow({
    required Key key,
    required String title,
    required List<Widget> pills,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(34, 0, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: YanciTheme.bodySmall.copyWith(
                color: SidebarVisualTokens.secondary.withValues(alpha: 0.78),
                fontSize: 12,
              ),
            ),
          ),
          ...pills,
        ],
      ),
    );
  }

  Widget _moodPill({
    required Key key,
    required String text,
    required String semantics,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final accent = SidebarVisualTokens.accent;
    final secondary = SidebarVisualTokens.secondary;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Semantics(
        button: true,
        selected: selected,
        label: semantics,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: selected
                        ? accent.withValues(alpha: 0.5)
                        : secondary.withValues(alpha: 0.22),
                    width: 0.6,
                  ),
                ),
                child: Text(
                  text,
                  style: YanciTheme.bodySmall.copyWith(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? accent : secondary.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _setAvatars(bool value) async {
    final previous = _showAvatars;
    setState(() {
      _showAvatars = value;
      _savingAvatars = true;
    });
    try {
      await UserSettings.saveShowChatAvatar(value);
    } catch (_) {
      if (mounted) setState(() => _showAvatars = previous);
    } finally {
      if (mounted) setState(() => _savingAvatars = false);
    }
  }

  Widget _entry(
    BuildContext context, {
    required String title,
    required CostContextSection section,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          minVerticalPadding: 11,
          title: Text(
            title,
            style: YanciTheme.bodyText.copyWith(
              color: SidebarVisualTokens.secondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          trailing: Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: SidebarVisualTokens.secondary.withValues(alpha: 0.62),
          ),
          onTap: () {
            HoltSidebarShell.maybeOf(context)?.close();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CostContextScreen(section: section),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // UI_SLOT: sidebar_behavior_output
        _entry(
          context,
          title: L.pick(
            en: 'Behavior / Output',
            zhTW: '對話行為／輸出格式',
            zhCN: '对话行为／输出格式',
          ),
          section: CostContextSection.behavior,
        ),
        // UI_SLOT: sidebar_prompt_modules
        _entry(
          context,
          title: L.pick(
            en: 'Feature modules (prompt switches)',
            zhTW: '功能模組（提示詞開關）',
            zhCN: '功能模块（提示词开关）',
          ),
          section: CostContextSection.modules,
        ),
        // UI_SLOT: sidebar_avatar_visibility
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 18),
          title: Text(
            L.pick(en: 'Chat avatars', zhTW: '頭像顯示', zhCN: '头像显示'),
            style: YanciTheme.bodyText.copyWith(
              color: SidebarVisualTokens.secondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          trailing: Transform.scale(
            scale: 0.78,
            alignment: Alignment.centerRight,
            child: Switch.adaptive(
              value: _showAvatars ?? false,
              onChanged: _showAvatars == null || _savingAvatars
                  ? null
                  : _setAvatars,
            ),
          ),
          onTap: _showAvatars == null || _savingAvatars
              ? null
              : () => _setAvatars(!_showAvatars!),
        ),
        _moodGlowRow(),
        if (_moodScope != null && _moodScope != MoodGlowScope.off)
          _moodBlendRow(),
        ListTile(
          key: const ValueKey('sidebar-reply-notifications'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18),
          title: Text(
            L.pick(en: 'Reply notifications', zhTW: '回覆通知', zhCN: '回复通知'),
            style: YanciTheme.bodyText.copyWith(
              color: SidebarVisualTokens.secondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          trailing: Transform.scale(
            scale: 0.78,
            alignment: Alignment.centerRight,
            child: Switch.adaptive(
              key: const ValueKey('reply-notification-switch'),
              value: _replyNotifications ?? true,
              onChanged:
                  _replyNotifications == null || _savingReplyNotifications
                  ? null
                  : _setReplyNotifications,
            ),
          ),
          onTap: _replyNotifications == null || _savingReplyNotifications
              ? null
              : () => _setReplyNotifications(!_replyNotifications!),
        ),
        // UI_SLOT: sidebar_memory_role
        _entry(
          context,
          title: L.pick(en: 'Memory & Role', zhTW: '記憶與角色功能', zhCN: '记忆与角色功能'),
          section: CostContextSection.memory,
        ),
      ],
    );
  }
}
