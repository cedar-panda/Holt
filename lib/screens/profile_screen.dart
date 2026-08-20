import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../services/settings_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';

/// Profile／交流指南。
///
/// This screen owns the same global system-prompt setting that used to live
/// in API Settings. The storage key and request injection path stay in
/// ApiSettings and the chat generation layer; this is only its UI location.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _profileController = TextEditingController();
  Timer? _saveTimer;
  Future<void>? _saveTask;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _profileController.text = await ApiSettings.getSystemPrompt();
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  void _scheduleSave() {
    if (_isLoading) return;
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
      return;
    }

    final task = ApiSettings.saveSystemPrompt(_profileController.text.trim());
    _saveTask = task;
    try {
      await task;
    } finally {
      if (identical(_saveTask, task)) _saveTask = null;
    }
  }

  Future<void> _saveNow() async {
    await _flushPendingSave();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L.pick(en: 'Profile saved', zhTW: 'Profile 已儲存')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleBack() async {
    await _flushPendingSave();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
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
                            L.pick(
                              en: 'Profile',
                              zhTW: 'Profile',
                              zhCN: 'Profile',
                            ),
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
                          padding: const EdgeInsets.all(YanciTheme.spacingMd),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
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
                                  en: 'Describe how you want the character to communicate with you. This is the global system prompt used by chat and calls.',
                                  zhTW: '描述你希望角色如何與你交流。這是聊天與通話共用的全域系統提示。',
                                  zhCN: '描述你希望角色如何与你交流。这是聊天与通话共用的全局系统提示。',
                                ),
                                style: YanciTheme.bodySmall.copyWith(
                                  fontSize: 11,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.65,
                                  ),
                                ),
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              _buildGlassCard(
                                child: TextField(
                                  key: const Key('profile_system_prompt_field'),
                                  controller: _profileController,
                                  minLines: 10,
                                  maxLines: null,
                                  style: YanciTheme.bodyText.copyWith(
                                    fontSize: 14,
                                  ),
                                  onChanged: (_) => _scheduleSave(),
                                  decoration: InputDecoration(
                                    hintText: L.pick(
                                      en: 'Write your communication guide…\n(Changing this invalidates the current static cache)',
                                      zhTW: '填寫你的交流指南…\n（改動會打斷目前的靜態緩存狀態）',
                                      zhCN: '填写你的交流指南…\n（改动会打断目前的静态缓存状态）',
                                    ),
                                    hintStyle: YanciTheme.bodySmall.copyWith(
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.45),
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: YanciTheme.spacingSm,
                                    ),
                                  ),
                                ),
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
