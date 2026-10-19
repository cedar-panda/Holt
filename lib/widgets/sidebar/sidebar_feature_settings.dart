import 'package:flutter/material.dart';

import '../../screens/cost_context_screen.dart';
import '../../services/locale_strings.dart';
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

  @override
  void initState() {
    super.initState();
    _loadAvatars();
  }

  Future<void> _loadAvatars() async {
    final value = await UserSettings.getShowChatAvatar();
    if (mounted) setState(() => _showAvatars = value);
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
