import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';
import '../models/context_mode.dart';
import '../services/settings/context_mode_settings.dart';
import '../services/user_persona_service.dart';
import '../widgets/context_mode_pill.dart';

/// Profile／交流指南。
///
/// The communication guide is stored per user role and mode. Its request slot
/// remains the existing system-prompt slot; only the cache content changes.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.initialMode, this.personaId});

  final ContextMode? initialMode;
  final String? personaId;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _profileController = TextEditingController();
  Timer? _saveTimer;
  Future<void>? _saveTask;
  int _editRevision = 0;
  int _savedRevision = 0;
  bool _isLoading = true;
  ContextMode _mode = ContextMode.daily;
  String _personaId = UserPersonaService.defaultPersonaId;

  @override
  void initState() {
    super.initState();
    ContextModeSettings.revision.addListener(_handleContextModeChanged);
    _load();
  }

  Future<void> _load() async {
    _personaId = widget.personaId?.trim().isNotEmpty == true
        ? widget.personaId!.trim()
        : (await UserPersonaService.selectedPersona()).id;
    final characterId = widget.initialMode == null
        ? await UserSettings.getActiveCharacterId()
        : '';
    final mode =
        widget.initialMode ??
        (characterId.isEmpty
            ? ContextMode.daily
            : await ContextModeSettings.effectiveMode(characterId));
    _mode = mode;
    _profileController.text = await UserPersonaService.profileGuide(
      _personaId,
      _mode,
    );
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  void _scheduleSave() {
    if (_isLoading) return;
    _editRevision++;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flushPendingSave()),
    );
  }

  Future<void> _flushPendingSave() async {
    _saveTimer?.cancel();
    final running = _saveTask;
    if (running != null) {
      await running;
    }

    while (_savedRevision < _editRevision) {
      final targetRevision = _editRevision;
      final personaId = _personaId;
      final mode = _mode;
      final value = _profileController.text;
      final task = UserPersonaService.saveProfileGuide(personaId, mode, value);
      _saveTask = task;
      try {
        await task;
        _savedRevision = targetRevision;
      } finally {
        if (identical(_saveTask, task)) _saveTask = null;
      }
    }
  }

  Future<void> _switchMode(ContextMode mode) async {
    await _flushPendingSave();
    final value = await UserPersonaService.profileGuide(_personaId, mode);
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _profileController.text = value;
      _editRevision = 0;
      _savedRevision = 0;
    });
  }

  void _handleContextModeChanged() {
    if (!mounted) return;
    unawaited(_syncEffectiveMode());
  }

  Future<void> _syncEffectiveMode() async {
    await _flushPendingSave();
    final characterId = await UserSettings.getActiveCharacterId();
    if (characterId.isEmpty) return;
    final mode = await ContextModeSettings.effectiveMode(characterId);
    if (!mounted || mode == _mode) return;
    await _switchMode(mode);
  }

  Future<void> _saveNow() async {
    await _flushPendingSave();
    if (!mounted) return;
    showThemedPillNotice(
      context,
      L.pick(
        en: 'Profile saved. New chats will use this version.',
        zhTW: 'Profile 已儲存，新窗口將使用此版本',
        zhCN: 'Profile 已保存，新窗口将使用此版本',
      ),
    );
  }

  Future<void> _handleBack() async {
    await _flushPendingSave();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    ContextModeSettings.revision.removeListener(_handleContextModeChanged);
    _saveTimer?.cancel();
    _profileController.dispose();
    super.dispose();
  }

  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: YanciTheme.spacingMd,
            vertical: YanciTheme.spacingSm,
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

  void _showExpandedGuideEditor() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final bottomInset = MediaQuery.viewInsetsOf(sheetContext).bottom;
        return AnimatedPadding(
          duration: MediaQuery.disableAnimationsOf(sheetContext)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(bottom: bottomInset),
          child: DraggableScrollableSheet(
            initialChildSize: 0.9,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            builder: (context, scrollController) => Container(
              decoration: BoxDecoration(
                color: YanciTheme.isDark
                    ? const Color(0xF0252228)
                    : Colors.white.withValues(alpha: 0.98),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(YanciTheme.radiusLg),
                ),
              ),
              child: Column(
                children: <Widget>[
                  const SizedBox(height: YanciTheme.spacingMd),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(YanciTheme.spacingMd),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            L.pick(
                              en: 'Communication guide',
                              zhTW: '交流指南',
                              zhCN: '交流指南',
                            ),
                            style: YanciTheme.headingMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: L.pick(en: 'Close', zhTW: '關閉', zhCN: '关闭'),
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: Icon(
                            Icons.close_fullscreen_rounded,
                            size: 20,
                            color: YanciTheme.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: YanciTheme.spacingMd,
                      ),
                      child: TextField(
                        key: const Key('profile_system_prompt_expanded_field'),
                        controller: _profileController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        scrollPadding: EdgeInsets.only(
                          bottom: bottomInset + YanciTheme.spacingXl,
                        ),
                        style: YanciTheme.bodyText.copyWith(fontSize: 14),
                        onChanged: (_) => _scheduleSave(),
                        decoration: InputDecoration(
                          hintText: L.pick(
                            en: 'Write your communication guide…',
                            zhTW: '填寫你的交流指南…',
                            zhCN: '填写你的交流指南…',
                          ),
                          hintStyle: YanciTheme.bodySmall.copyWith(
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.45,
                            ),
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 允許右滑返回：彈出時補存最後一次修改（_flushPendingSave 只讀
      // controller 文字、不 setState，頁面卸載後也能跑完）。
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(_flushPendingSave().catchError((_) {}));
        } else {
          unawaited(_handleBack());
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
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
                            L.pick(en: 'Profile', zhTW: '相處方式', zhCN: '相处方式'),
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
                            onPressed: _handleBack,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: EdgeInsets.fromLTRB(
                            YanciTheme.spacingMd,
                            YanciTheme.spacingMd,
                            YanciTheme.spacingMd,
                            MediaQuery.viewInsetsOf(context).bottom +
                                YanciTheme.spacingXl,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(
                                child: ContextModePill(
                                  mode: _mode,
                                  onChanged: (mode) =>
                                      unawaited(_switchMode(mode)),
                                ),
                              ),
                              const SizedBox(height: YanciTheme.spacingMd),
                              Text(
                                L.pick(
                                  en: 'Communication guide',
                                  zhTW: '交流指南',
                                  zhCN: '交流指南',
                                ),
                                style: YanciTheme.bodySmall.copyWith(
                                  color: YanciTheme.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              Text(
                                L.pick(
                                  en: _mode == ContextMode.rp
                                      ? 'Optional RP communication guide. Holt does not add a built-in RP style; your character card and this profile remain in control.'
                                      : 'Describe how you want the character to communicate with you. This profile is shared by daily chats and calls.',
                                  zhTW: _mode == ContextMode.rp
                                      ? '可選的 RP 交流指南。Holt 不會加入內建 RP 生成風格；內容由你的角色卡與此 Profile 決定。'
                                      : '描述你希望角色如何與你交流。此 Profile 供日常聊天與通話使用。',
                                  zhCN: _mode == ContextMode.rp
                                      ? '可选的 RP 交流指南。Holt 不会加入内置 RP 生成风格；内容由你的角色卡与此 Profile 决定。'
                                      : '描述你希望角色如何与你交流。此 Profile 供日常聊天与通话使用。',
                                ),
                                style: YanciTheme.bodySmall.copyWith(
                                  fontSize: 11,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.65,
                                  ),
                                ),
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              Stack(
                                children: <Widget>[
                                  _buildGlassCard(
                                    child: TextField(
                                      key: const Key(
                                        'profile_system_prompt_field',
                                      ),
                                      controller: _profileController,
                                      minLines: 10,
                                      maxLines: null,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 14,
                                      ),
                                      onChanged: (_) => _scheduleSave(),
                                      decoration: InputDecoration(
                                        hintText: L.pick(
                                          en: 'Write your communication guide…\n(New chats use the update; existing chats keep their birth version)',
                                          zhTW:
                                              '填寫你的交流指南…\n（新窗口使用更新；既有窗口保留建立時版本）',
                                          zhCN:
                                              '填写你的交流指南…\n（新窗口使用更新；既有窗口保留创建时版本）',
                                        ),
                                        hintStyle: YanciTheme.bodySmall
                                            .copyWith(
                                              color: YanciTheme.textSecondary
                                                  .withValues(alpha: 0.45),
                                            ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.fromLTRB(
                                              0,
                                              YanciTheme.spacingSm,
                                              30,
                                              YanciTheme.spacingSm,
                                            ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: IconButton(
                                      key: const Key(
                                        'profile-expand-guide-button',
                                      ),
                                      tooltip: L.pick(
                                        en: 'Expand editor',
                                        zhTW: '放大編輯',
                                        zhCN: '放大编辑',
                                      ),
                                      onPressed: _showExpandedGuideEditor,
                                      icon: Icon(
                                        Icons.open_in_full_rounded,
                                        size: 17,
                                        color: YanciTheme.accent.withValues(
                                          alpha: 0.58,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: YanciTheme.spacingMd),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  key: const Key('profile_save_button'),
                                  onPressed: _saveNow,
                                  icon: const Icon(Icons.save_outlined),
                                  label: Text(
                                    L.pick(
                                      en: 'Save profile',
                                      zhTW: '儲存 Profile',
                                      zhCN: '保存 Profile',
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
