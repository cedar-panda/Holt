import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart' show themeNotifier;
import '../memory/database.dart';
import '../services/initial_setup_service.dart';
import '../services/locale_strings.dart';
import '../services/settings/theme_settings.dart';
import '../services/settings/memory_settings.dart';
import '../services/settings/user_settings.dart';
import '../services/static_token_estimator.dart';
import 'splash_screen.dart';
import '../theme/app_theme.dart';
import '../theme/theme_presets.dart';
import '../widgets/gradient_background.dart';
import '../widgets/yanci_bottom_nav_bar.dart';

final _lightThemePresets = presets
    .where((preset) => !preset.isDark)
    .toList(growable: false);
final _darkThemePresets = presets
    .where((preset) => preset.isDark)
    .toList(growable: false);

/// 首次語言選擇後的功能方案、姓名、精簡 TA 人設與主題選擇。
///
/// 這不是功能導覽：完成後的 API、摘要模型與新視窗提示都由各自畫面內的
/// 弱引導負責，並共同尊重 [UserSettings.isWeakGuidanceEnabled]。
class InitialSetupScreen extends StatefulWidget {
  const InitialSetupScreen({super.key});

  @override
  State<InitialSetupScreen> createState() => _InitialSetupScreenState();
}

class _InitialSetupScreenState extends State<InitialSetupScreen> {
  final _userNameController = TextEditingController();
  final _characterNameController = TextEditingController();
  final _genderController = TextEditingController();
  final _relationshipController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _userNameFocus = FocusNode();
  final _characterNameFocus = FocusNode();
  late final PageController _lightThemeCarouselController;
  late final PageController _darkThemeCarouselController;

  int _step = 0;
  late int _lightPreviewIndex;
  late int _darkPreviewIndex;
  bool _busy = false;
  bool _showCharacterNameError = false;
  bool _characterCommitted = false;
  bool _choosingDarkTheme = false;
  bool _lightThemeConfirmed = false;
  bool _darkThemeConfirmed = false;
  bool _themeSelectionTouched = false;
  bool _hasExistingCharacter = false;
  String _selectedMode = 'advanced';
  bool _customEmotion = true;
  bool _customBioclock = true;
  bool _customTimeline = true;
  bool _customAvatar = false;
  bool _customSelfNotes = true;

  @override
  void initState() {
    super.initState();
    final activePreset = YanciTheme.preset;
    _lightPreviewIndex = _presetIndex(
      _lightThemePresets,
      activePreset.isDark ? 'ivory' : activePreset.id,
    );
    _darkPreviewIndex = _presetIndex(
      _darkThemePresets,
      activePreset.isDark ? activePreset.id : 'nightlamp',
    );
    _lightThemeCarouselController = PageController(
      viewportFraction: 0.22,
      initialPage: _lightPreviewIndex,
    );
    _darkThemeCarouselController = PageController(
      viewportFraction: 0.22,
      initialPage: _darkPreviewIndex,
    );
    _restoreProgress();
  }

  int _presetIndex(List<ThemePreset> choices, String id) {
    final index = choices.indexWhere((preset) => preset.id == id);
    return index < 0 ? 0 : index;
  }

  Future<void> _restoreProgress() async {
    final name = await UserSettings.getUserName();
    final savedStep = await UserSettings.getInitialSetupStep();
    var hasExistingCharacter = false;
    try {
      hasExistingCharacter = await InitialSetupService.hasExistingCharacter();
    } catch (_) {
      // The first frame must remain usable while the local database is still
      // being initialized (and in widget tests without a sqflite factory).
    }
    final savedMode = await UserSettings.getInitialSetupMode();
    final savedEmotion = await MemorySettings.isAbilityEnabled('emotion');
    final savedBioclock = await MemorySettings.isAbilityEnabled('bioclock');
    final savedTimeline = await MemorySettings.getTimelineEnabled();
    final savedSelfNotes = await MemorySettings.getSelfNotesEnabled();
    final savedAvatar = await UserSettings.getShowChatAvatar();
    final savedLightPreset = await ThemeSettings.getLastLightPreset();
    final savedDarkPreset = await ThemeSettings.getLastDarkPreset();
    final activeCharacterId = savedStep >= 3
        ? await UserSettings.getActiveCharacterId()
        : 'default';
    if (!mounted) return;
    if (name.isNotEmpty) _userNameController.text = name;
    setState(() {
      _selectedMode = savedMode.isEmpty ? 'advanced' : savedMode;
      _customEmotion = savedEmotion;
      _customBioclock = savedBioclock;
      _customTimeline = savedTimeline;
      _customSelfNotes = savedSelfNotes;
      _customAvatar = savedAvatar;
      _hasExistingCharacter = hasExistingCharacter;
      // 明確保存的第 1 頁優先於舊方案值；切回語言選擇再回來時，
      // 必須從 1 → 2 → 3 → 4 重新順序進入。
      _step = savedStep == 0
          ? 0
          : (savedMode.isEmpty
                ? (savedStep >= 2 || name.isNotEmpty ? 2 : 1)
                : (hasExistingCharacter
                      ? 3
                      : (savedStep >= 3
                            ? 3
                            : (savedStep >= 2 || name.isNotEmpty ? 2 : 1))));
      _characterCommitted =
          hasExistingCharacter ||
          (savedStep >= 3 && activeCharacterId != 'default');
      if (!_themeSelectionTouched) {
        final activePreset = YanciTheme.preset;
        _lightPreviewIndex = _presetIndex(
          _lightThemePresets,
          activePreset.isDark ? savedLightPreset : activePreset.id,
        );
        _darkPreviewIndex = _presetIndex(
          _darkThemePresets,
          activePreset.isDark ? activePreset.id : savedDarkPreset,
        );
      }
    });
    if (!_themeSelectionTouched) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_lightThemeCarouselController.hasClients) {
          _lightThemeCarouselController.jumpToPage(_lightPreviewIndex);
        }
        if (_darkThemeCarouselController.hasClients) {
          _darkThemeCarouselController.jumpToPage(_darkPreviewIndex);
        }
      });
    }
  }

  @override
  void dispose() {
    _userNameController.dispose();
    _characterNameController.dispose();
    _genderController.dispose();
    _relationshipController.dispose();
    _descriptionController.dispose();
    _userNameFocus.dispose();
    _characterNameFocus.dispose();
    _lightThemeCarouselController.dispose();
    _darkThemeCarouselController.dispose();
    super.dispose();
  }

  Future<void> _continueFromName() async {
    if (_busy) return;
    final name = _userNameController.text.trim();
    if (name.isNotEmpty) await UserSettings.saveUserName(name);
    await UserSettings.saveInitialSetupStep(2);
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() => _step = 2);
  }

  Future<void> _skipName() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await UserSettings.saveInitialSetupStep(2);
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() => _step = 2);
  }

  Future<void> _saveCharacter() async {
    if (_busy) return;
    final name = _characterNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _showCharacterNameError = true);
      _characterNameFocus.requestFocus();
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    try {
      await InitialSetupService.createCharacter(
        InitialCharacterDraft(
          name: name,
          gender: _genderController.text,
          relationship: _relationshipController.text,
          description: _descriptionController.text,
        ),
      );
      await UserSettings.saveInitialSetupStep(3);
      if (!mounted) return;
      HapticFeedback.selectionClick();
      setState(() {
        _busy = false;
        _step = 3;
        _characterCommitted = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Could not create TA. Please try again.',
              zhTW: '暫時無法建立 TA，請再試一次。',
            ),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _skipCharacter() async {
    if (_busy) return;
    setState(() => _busy = true);
    await UserSettings.saveInitialSetupStep(3);
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _busy = false;
      _step = 3;
      _characterCommitted = false;
    });
  }

  void _selectThemeMode(bool dark) {
    if (_busy || _choosingDarkTheme == dark) return;
    HapticFeedback.selectionClick();
    setState(() {
      _themeSelectionTouched = true;
      _choosingDarkTheme = dark;
    });
    _syncActiveThemeCarouselAfterBuild();
  }

  void _syncActiveThemeCarouselAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = _choosingDarkTheme
          ? _darkThemeCarouselController
          : _lightThemeCarouselController;
      final index = _choosingDarkTheme ? _darkPreviewIndex : _lightPreviewIndex;
      if (controller.hasClients && controller.page?.round() != index) {
        controller.jumpToPage(index);
      }
    });
  }

  void _previewTheme(int index) {
    final currentIndex = _choosingDarkTheme
        ? _darkPreviewIndex
        : _lightPreviewIndex;
    if (currentIndex == index) return;
    HapticFeedback.selectionClick();
    setState(() {
      _themeSelectionTouched = true;
      if (_choosingDarkTheme) {
        _darkPreviewIndex = index;
        _darkThemeConfirmed = false;
      } else {
        _lightPreviewIndex = index;
        _lightThemeConfirmed = false;
      }
    });
  }

  Future<void> _confirmPreviewedTheme() async {
    if (_busy) return;
    HapticFeedback.selectionClick();
    final confirmingDark = _choosingDarkTheme;
    setState(() {
      _themeSelectionTouched = true;
      if (confirmingDark) {
        _darkThemeConfirmed = true;
      } else {
        _lightThemeConfirmed = true;
      }
    });

    if (!_lightThemeConfirmed || !_darkThemeConfirmed) {
      setState(
        () => _choosingDarkTheme = _lightThemeConfirmed && !_darkThemeConfirmed,
      );
      _syncActiveThemeCarouselAfterBuild();
      return;
    }

    final activateDark = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _ThemeStartSheet(
        lightPreset: _lightThemePresets[_lightPreviewIndex],
        darkPreset: _darkThemePresets[_darkPreviewIndex],
      ),
    );
    if (activateDark == null || !mounted) return;
    await _applyThemePair(activateDark: activateDark);
  }

  Future<void> _applyThemePair({required bool activateDark}) async {
    if (_busy) return;
    final lightPreset = _lightThemePresets[_lightPreviewIndex];
    final darkPreset = _darkThemePresets[_darkPreviewIndex];
    final activePreset = activateDark ? darkPreset : lightPreset;
    final previousId = YanciTheme.presetId;
    final previousLightId = await ThemeSettings.getLastLightPreset();
    final previousDarkId = await ThemeSettings.getLastDarkPreset();
    final previousPreset = findPreset(previousId);
    final rollbackLightId = previousPreset.isDark
        ? previousLightId
        : previousId;
    final rollbackDarkId = previousPreset.isDark ? previousId : previousDarkId;
    if (!mounted) return;
    setState(() => _busy = true);

    try {
      await ThemeSettings.saveThemePair(
        lightPresetId: lightPreset.id,
        darkPresetId: darkPreset.id,
        activePresetId: activePreset.id,
      );
      YanciTheme.setPreset(activePreset.id);
      themeNotifier.value++;
      await _completeAndOpenHome(skipAllGuidance: false);
    } catch (_) {
      await ThemeSettings.saveThemePair(
        lightPresetId: rollbackLightId,
        darkPresetId: rollbackDarkId,
        activePresetId: previousId,
      );
      YanciTheme.setPreset(previousId);
      themeNotifier.value++;
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Could not save the themes. Please try again.',
              zhTW: '暫時無法保存日夜主題，請再試一次。',
            ),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _skipTheme() => _finish(skipAllGuidance: false);

  Future<void> _continueFromMode(String mode) async {
    if (_busy) return;
    setState(() => _busy = true);
    await UserSettings.saveInitialSetupMode(mode);
    if (mode == 'basic') {
      await MemorySettings.setAbilityEnabled('emotion', false);
      await MemorySettings.setAbilityEnabled('bioclock', false);
      await MemorySettings.saveTimelineEnabled(false);
      await MemorySettings.saveSelfNotesEnabled(true);
      await MemorySettings.saveTimelinePromptMode('normal');
    } else if (mode == 'advanced') {
      await MemorySettings.setAbilityEnabled('emotion', true);
      await MemorySettings.setAbilityEnabled('bioclock', true);
      await MemorySettings.saveTimelineEnabled(true);
      await MemorySettings.saveSelfNotesEnabled(true);
      await MemorySettings.saveTimelinePromptMode('normal');
    } else if (mode == 'rp') {
      await MemorySettings.setAbilityEnabled('emotion', false);
      await MemorySettings.setAbilityEnabled('bioclock', false);
      await MemorySettings.saveTimelineEnabled(true);
      await MemorySettings.saveSelfNotesEnabled(false);
      await MemorySettings.saveTimelinePromptMode('plot');
    } else {
      await MemorySettings.setAbilityEnabled('emotion', _customEmotion);
      await MemorySettings.setAbilityEnabled('bioclock', _customBioclock);
      await MemorySettings.saveTimelineEnabled(_customTimeline);
      await MemorySettings.saveSelfNotesEnabled(_customSelfNotes);
      await UserSettings.saveShowChatAvatar(_customAvatar);
      await MemorySettings.saveTimelinePromptMode('normal');
    }
    // 方案只設定預設值；不鎖定策略。已有角色重新走引導時，先套用
    // 「含記憶方案預設使用蛛網記憶」，之後仍可在能力模組切回經典記憶。
    if (_hasExistingCharacter) {
      final activeId = await UserSettings.getActiveCharacterId();
      if (activeId != 'default') {
        await DatabaseHelper.updateCharacter(activeId, {
          'is_spider_web_enabled': 1,
        });
      }
    }
    if (mounted) StaticTokenEstimator.showAfterToggle(context);
    final nextStep = _hasExistingCharacter ? 3 : 1;
    await UserSettings.saveInitialSetupStep(nextStep);
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _busy = false;
      _step = nextStep;
    });
  }

  Future<void> _skipAllGuidance() => _finish(skipAllGuidance: true);

  Future<void> _returnToLanguageSelection() async {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await UserSettings.saveInitialSetupStep(0);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const SplashScreen(showLanguagePicker: true),
      ),
    );
  }

  Future<void> _finish({required bool skipAllGuidance}) async {
    if (_busy) return;
    setState(() => _busy = true);
    await _completeAndOpenHome(skipAllGuidance: skipAllGuidance);
  }

  Future<void> _completeAndOpenHome({required bool skipAllGuidance}) async {
    await UserSettings.completeInitialSetup(skipAllGuidance: skipAllGuidance);
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
  }

  Future<void> _returnToPreviousStep() async {
    if (_busy || _step == 0) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_step == 3) {
      // 已建立正式角色後不回到建立表單，避免重複產生角色資料。
      if (_characterCommitted) return;
      await UserSettings.saveInitialSetupStep(2);
      if (mounted) setState(() => _step = 2);
      return;
    }
    if (_step == 2) {
      await UserSettings.saveInitialSetupStep(1);
      if (mounted) setState(() => _step = 1);
      return;
    }
    await UserSettings.saveInitialSetupStep(0);
    if (mounted) setState(() => _step = 0);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _returnToPreviousStep();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        body: GradientBackground(
          child: SafeArea(
            child: AnimatedSwitcher(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: switch (_step) {
                0 => _ModeStep(
                  key: const ValueKey('initial-mode-step'),
                  selectedMode: _selectedMode,
                  customEmotion: _customEmotion,
                  customBioclock: _customBioclock,
                  customTimeline: _customTimeline,
                  customAvatar: _customAvatar,
                  customSelfNotes: _customSelfNotes,
                  busy: _busy,
                  onBack: _returnToLanguageSelection,
                  onModeChanged: (mode) => setState(() => _selectedMode = mode),
                  onCustomChanged: (key, value) {
                    setState(() {
                      switch (key) {
                        case 'emotion':
                          _customEmotion = value;
                        case 'bioclock':
                          _customBioclock = value;
                        case 'timeline':
                          _customTimeline = value;
                        case 'avatar':
                          _customAvatar = value;
                        case 'selfNotes':
                          _customSelfNotes = value;
                      }
                    });
                  },
                  onContinue: () => _continueFromMode(_selectedMode),
                  onSkip: () => _continueFromMode(_selectedMode),
                  onSkipAll: _skipAllGuidance,
                ),
                1 => _NameStep(
                  key: const ValueKey('initial-name-step'),
                  controller: _userNameController,
                  focusNode: _userNameFocus,
                  busy: _busy,
                  onBack: _returnToPreviousStep,
                  onContinue: _continueFromName,
                  onSkip: _skipName,
                  onSkipAll: _skipAllGuidance,
                ),
                2 => _CharacterStep(
                  key: const ValueKey('initial-character-step'),
                  nameController: _characterNameController,
                  genderController: _genderController,
                  relationshipController: _relationshipController,
                  descriptionController: _descriptionController,
                  nameFocusNode: _characterNameFocus,
                  busy: _busy,
                  onBack: _returnToPreviousStep,
                  showNameError: _showCharacterNameError,
                  onNameChanged: (_) {
                    if (_showCharacterNameError) {
                      setState(() => _showCharacterNameError = false);
                    }
                  },
                  onSave: _saveCharacter,
                  onSkip: _skipCharacter,
                  onSkipAll: _skipAllGuidance,
                ),
                _ => _ThemeStep(
                  key: const ValueKey('initial-theme-step'),
                  presets: _choosingDarkTheme
                      ? _darkThemePresets
                      : _lightThemePresets,
                  preset: _choosingDarkTheme
                      ? _darkThemePresets[_darkPreviewIndex]
                      : _lightThemePresets[_lightPreviewIndex],
                  lightPreset: _lightThemePresets[_lightPreviewIndex],
                  darkPreset: _darkThemePresets[_darkPreviewIndex],
                  previewIndex: _choosingDarkTheme
                      ? _darkPreviewIndex
                      : _lightPreviewIndex,
                  controller: _choosingDarkTheme
                      ? _darkThemeCarouselController
                      : _lightThemeCarouselController,
                  choosingDarkTheme: _choosingDarkTheme,
                  lightThemeConfirmed: _lightThemeConfirmed,
                  darkThemeConfirmed: _darkThemeConfirmed,
                  busy: _busy,
                  reduceMotion: reduceMotion,
                  onBack: _returnToPreviousStep,
                  onSelectLight: () => _selectThemeMode(false),
                  onSelectDark: () => _selectThemeMode(true),
                  onPreviewChanged: _previewTheme,
                  onApply: _confirmPreviewedTheme,
                  onSkip: _skipTheme,
                  onSkipAll: _skipAllGuidance,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeStep extends StatelessWidget {
  const _ModeStep({
    super.key,
    required this.selectedMode,
    required this.customEmotion,
    required this.customBioclock,
    required this.customTimeline,
    required this.customAvatar,
    required this.customSelfNotes,
    required this.busy,
    required this.onBack,
    required this.onModeChanged,
    required this.onCustomChanged,
    required this.onContinue,
    required this.onSkip,
    required this.onSkipAll,
  });

  final String selectedMode;
  final bool customEmotion;
  final bool customBioclock;
  final bool customTimeline;
  final bool customAvatar;
  final bool customSelfNotes;
  final bool busy;
  final VoidCallback onBack;
  final ValueChanged<String> onModeChanged;
  final void Function(String key, bool value) onCustomChanged;
  final VoidCallback onContinue;
  final VoidCallback onSkip;
  final VoidCallback onSkipAll;

  String _label(String mode) => switch (mode) {
    'basic' => L.pick(en: 'Basic', zhTW: '基礎', zhCN: '基础'),
    'advanced' => L.pick(en: 'Advanced', zhTW: '進階', zhCN: '进阶'),
    'rp' => 'RP',
    _ => L.pick(en: 'Custom', zhTW: '自定義', zhCN: '自定义'),
  };

  String _description(String mode) => switch (mode) {
    'basic' => L.pick(en: 'Memory stays on', zhTW: '記憶開啟', zhCN: '记忆开启'),
    'advanced' => L.pick(
      en: 'Basic / Emotion / Bio clock / Timeline',
      zhTW: '基礎 / 情緒 / 生物鐘 / 時間線',
      zhCN: '基础 / 情绪 / 生物钟 / 时间线',
    ),
    'rp' => L.pick(
      en: 'Memory / Story timeline',
      zhTW: '記憶 / 劇情時間線',
      zhCN: '记忆 / 剧情时间线',
    ),
    _ => L.pick(
      en: 'Choose each switch yourself',
      zhTW: '自行選擇各項開關',
      zhCN: '自行选择各项开关',
    ),
  };

  Widget _modeCard(BuildContext context, String mode) {
    final selected = selectedMode == mode;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Semantics(
          button: true,
          selected: selected,
          label: _label(mode),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: busy ? null : () => onModeChanged(mode),
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
              decoration: BoxDecoration(
                color: selected
                    ? YanciTheme.accent.withValues(alpha: 0.12)
                    : YanciTheme.glassInputBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected
                      ? YanciTheme.accent.withValues(alpha: 0.7)
                      : YanciTheme.glassBorder,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _label(mode),
                    textAlign: TextAlign.center,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: (YanciTheme.bodyText.fontSize ?? 15) + 2,
                      fontWeight: FontWeight.w800,
                      color: YanciTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _description(mode),
                    textAlign: TextAlign.center,
                    style: YanciTheme.bodySmall.copyWith(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.72),
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _customSwitch(
    String key,
    String title,
    String description,
    bool value,
  ) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: YanciTheme.bodyText.copyWith(fontSize: 14)),
      subtitle: Text(
        description,
        style: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary.withValues(alpha: 0.7),
        ),
      ),
      value: value,
      activeThumbColor: YanciTheme.accent,
      onChanged: busy ? null : (next) => onCustomChanged(key, next),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SetupLayout(
      topLeft: _BackButton(onPressed: busy ? null : onBack),
      topRight: _SkipButton(onPressed: busy ? null : onSkip),
      bottom: _SkipAllButton(onPressed: busy ? null : onSkipAll),
      alignContentToTop: true,
      centerAction: _PrimaryButton(
        onPressed: busy ? null : onContinue,
        label: L.pick(en: 'Continue', zhTW: '繼續', zhCN: '继续'),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L.pick(
                  en: 'Choose your memory setup',
                  zhTW: '選擇你們的相處模式',
                  zhCN: '选择你们的相处模式',
                ),
                style: YanciTheme.headingLarge.copyWith(
                  color: YanciTheme.textPrimary,
                  fontSize: 27,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                L.pick(
                  en: 'You can change these switches later in Me → Switches.',
                  zhTW: '之後可以在「我的 → 開關」裡修改。',
                  zhCN: '之后可以在“我的 → 开关”里修改。',
                ),
                style: YanciTheme.bodySmall.copyWith(height: 1.5),
              ),
              const SizedBox(height: 22),
              _modeCard(context, 'basic'),
              _modeCard(context, 'advanced'),
              _modeCard(context, 'rp'),
              _modeCard(context, 'custom'),
              if (selectedMode == 'custom')
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Container(
                      margin: const EdgeInsets.only(top: 2, bottom: 18),
                      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                      decoration: BoxDecoration(
                        color: YanciTheme.glassInputBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: YanciTheme.glassBorder),
                      ),
                      child: Column(
                        children: [
                          _customSwitch(
                            'emotion',
                            L.pick(en: 'Emotion', zhTW: '情緒', zhCN: '情绪'),
                            L.pick(
                              en: 'Inject emotion coordinates into replies.',
                              zhTW: '將情緒座標注入對話。',
                              zhCN: '将情绪坐标注入对话。',
                            ),
                            customEmotion,
                          ),
                          _customSwitch(
                            'bioclock',
                            L.pick(en: 'Bio clock', zhTW: '生物鐘', zhCN: '生物钟'),
                            L.pick(
                              en: 'Use fatigue and sleep rhythm cues.',
                              zhTW: '使用疲勞與作息提示。',
                              zhCN: '使用疲劳与作息提示。',
                            ),
                            customBioclock,
                          ),
                          _customSwitch(
                            'timeline',
                            L.pick(en: 'Timeline', zhTW: '時間線', zhCN: '时间线'),
                            L.pick(
                              en: 'Show and inject character timeline context.',
                              zhTW: '顯示並注入角色時間線內容。',
                              zhCN: '显示并注入角色时间线内容。',
                            ),
                            customTimeline,
                          ),
                          _customSwitch(
                            'avatar',
                            L.pick(
                              en: 'Chat avatars',
                              zhTW: '對話框內頭像',
                              zhCN: '对话框内头像',
                            ),
                            L.pick(
                              en: 'Show avatars beside chat bubbles.',
                              zhTW: '在對話氣泡旁顯示頭像。',
                              zhCN: '在对话气泡旁显示头像。',
                            ),
                            customAvatar,
                          ),
                          _customSwitch(
                            'selfNotes',
                            L.pick(
                              en: 'Secretly remembering you',
                              zhTW: '偷偷記住你',
                              zhCN: '偷偷记住你',
                            ),
                            L.pick(
                              en: 'Keep the quiet self-notes panel and prompt.',
                              zhTW: '保留安靜的自我註記面板與提示。',
                              zhCN: '保留安静的自我注记面板与提示。',
                            ),
                            customSelfNotes,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NameStep extends StatelessWidget {
  const _NameStep({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onBack,
    required this.onContinue,
    required this.onSkip,
    required this.onSkipAll,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onBack;
  final VoidCallback onContinue;
  final VoidCallback onSkip;
  final VoidCallback onSkipAll;

  @override
  Widget build(BuildContext context) {
    return _SetupLayout(
      topLeft: _BackButton(onPressed: busy ? null : onBack),
      topRight: _SkipButton(onPressed: busy ? null : onSkip),
      bottom: _SkipAllButton(onPressed: busy ? null : onSkipAll),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.pick(en: 'What should I call you?', zhTW: '怎麼稱呼你～'),
              key: const ValueKey('initial-name-title'),
              style: YanciTheme.headingLarge.copyWith(
                color: YanciTheme.textPrimary,
                fontSize: 27,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              L.pick(
                en: 'You can change this later in your profile.',
                zhTW: '之後也能在個人檔案裡修改。',
              ),
              style: YanciTheme.bodySmall.copyWith(height: 1.6),
            ),
            const SizedBox(height: 34),
            _SetupTextField(
              key: const ValueKey('initial-user-name'),
              label: L.pick(en: 'Your name', zhTW: '你的名字'),
              hint: L.pick(en: 'Enter a name', zhTW: '輸入稱呼'),
              controller: controller,
              focusNode: focusNode,
              autofocus: false,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.nickname],
              onSubmitted: (_) => onContinue(),
            ),
            const SizedBox(height: 28),
            _PrimaryButton(
              key: const ValueKey('initial-name-continue'),
              onPressed: busy ? null : onContinue,
              label: L.pick(en: 'Continue', zhTW: '繼續'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CharacterStep extends StatelessWidget {
  const _CharacterStep({
    super.key,
    required this.nameController,
    required this.genderController,
    required this.relationshipController,
    required this.descriptionController,
    required this.nameFocusNode,
    required this.busy,
    required this.onBack,
    required this.showNameError,
    required this.onNameChanged,
    required this.onSave,
    required this.onSkip,
    required this.onSkipAll,
  });

  final TextEditingController nameController;
  final TextEditingController genderController;
  final TextEditingController relationshipController;
  final TextEditingController descriptionController;
  final FocusNode nameFocusNode;
  final bool busy;
  final VoidCallback onBack;
  final bool showNameError;
  final ValueChanged<String> onNameChanged;
  final VoidCallback onSave;
  final VoidCallback onSkip;
  final VoidCallback onSkipAll;

  @override
  Widget build(BuildContext context) {
    return _SetupLayout(
      topLeft: _BackButton(onPressed: busy ? null : onBack),
      topRight: _SkipButton(onPressed: busy ? null : onSkip),
      bottom: _SkipAllButton(onPressed: busy ? null : onSkipAll),
      alignContentToTop: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TaTitle(),
            const SizedBox(height: 14),
            Text(
              L.pick(
                en: 'Start with only what matters. Everything can be refined later.',
                zhTW: '先留下最重要的部分，之後都能慢慢補充。',
              ),
              style: YanciTheme.bodySmall.copyWith(height: 1.6),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
              decoration: BoxDecoration(
                color: YanciTheme.glassInputBg.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                border: Border.all(
                  color: YanciTheme.glassBorder.withValues(alpha: 0.9),
                  width: 0.7,
                ),
              ),
              child: Column(
                children: [
                  _CompactSetupField(
                    key: const ValueKey('initial-character-name'),
                    label: L.get('char_name_label'),
                    hint: L.get('char_name'),
                    controller: nameController,
                    focusNode: nameFocusNode,
                    errorText: showNameError
                        ? L.get('char_name_required')
                        : null,
                    onChanged: onNameChanged,
                  ),
                  _CompactSetupField(
                    key: const ValueKey('initial-character-gender'),
                    label: L.get('char_gender_label'),
                    hint: L.get('char_gender_hint'),
                    controller: genderController,
                  ),
                  _CompactSetupField(
                    key: const ValueKey('initial-character-relationship'),
                    label: L.get('char_relation_label'),
                    hint: L.get('char_relation_hint'),
                    controller: relationshipController,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      L.pick(en: 'Introduction', zhTW: '簡介'),
                      style: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 7),
                  TextField(
                    key: const ValueKey('initial-character-description'),
                    controller: descriptionController,
                    minLines: 3,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    style: YanciTheme.bodyText.copyWith(
                      color: YanciTheme.textPrimary,
                      fontSize: 14,
                    ),
                    decoration: InputDecoration(
                      hintText: L.pick(
                        en: 'Personality, background, how TA gets along with you…',
                        zhTW: '個性、背景、TA 與你相處的樣子……',
                      ),
                      hintStyle: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.48),
                      ),
                      filled: true,
                      fillColor: YanciTheme.glassWhite.withValues(alpha: 0.16),
                      border: _fieldBorder(),
                      enabledBorder: _fieldBorder(),
                      focusedBorder: _fieldBorder(color: YanciTheme.accent),
                      contentPadding: const EdgeInsets.all(13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            _PrimaryButton(
              key: const ValueKey('initial-character-save'),
              onPressed: busy ? null : onSave,
              label: L.pick(en: 'Create TA', zhTW: '建立 TA'),
              busy: busy,
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeStep extends StatelessWidget {
  const _ThemeStep({
    super.key,
    required this.presets,
    required this.preset,
    required this.lightPreset,
    required this.darkPreset,
    required this.previewIndex,
    required this.controller,
    required this.choosingDarkTheme,
    required this.lightThemeConfirmed,
    required this.darkThemeConfirmed,
    required this.busy,
    required this.reduceMotion,
    required this.onBack,
    required this.onSelectLight,
    required this.onSelectDark,
    required this.onPreviewChanged,
    required this.onApply,
    required this.onSkip,
    required this.onSkipAll,
  });

  final List<ThemePreset> presets;
  final ThemePreset preset;
  final ThemePreset lightPreset;
  final ThemePreset darkPreset;
  final int previewIndex;
  final PageController controller;
  final bool choosingDarkTheme;
  final bool lightThemeConfirmed;
  final bool darkThemeConfirmed;
  final bool busy;
  final bool reduceMotion;
  final VoidCallback onBack;
  final VoidCallback onSelectLight;
  final VoidCallback onSelectDark;
  final ValueChanged<int> onPreviewChanged;
  final VoidCallback onApply;
  final VoidCallback onSkip;
  final VoidCallback onSkipAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                _BackButton(onPressed: busy ? null : onBack),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    L.pick(en: 'Choose day and night', zhTW: '選擇日間與夜間主題'),
                    key: const ValueKey('initial-theme-title'),
                    style: YanciTheme.headingMedium.copyWith(
                      color: YanciTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                _SkipButton(onPressed: busy ? null : onSkip),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              L.pick(
                en: 'Pick one for each. They apply only after your final choice.',
                zhTW: '日間與夜間各選一款，最後確認後才會套用。',
              ),
              style: YanciTheme.bodySmall.copyWith(height: 1.5),
            ),
          ),
          const SizedBox(height: 8),
          _ThemeModeTabs(
            choosingDarkTheme: choosingDarkTheme,
            lightPreset: lightPreset,
            darkPreset: darkPreset,
            lightThemeConfirmed: lightThemeConfirmed,
            darkThemeConfirmed: darkThemeConfirmed,
            reduceMotion: reduceMotion,
            onSelectLight: onSelectLight,
            onSelectDark: onSelectDark,
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _ThemePreview(preset: preset, reduceMotion: reduceMotion),
          ),
          const SizedBox(height: 6),
          _ThemeWheel(
            presets: presets,
            controller: controller,
            previewIndex: previewIndex,
            isDarkMode: choosingDarkTheme,
            reduceMotion: reduceMotion,
            onPreviewChanged: onPreviewChanged,
          ),
          const SizedBox(height: 4),
          _PrimaryButton(
            key: const ValueKey('initial-theme-apply'),
            onPressed: busy ? null : onApply,
            label: lightThemeConfirmed && darkThemeConfirmed
                ? L.pick(en: 'Finish theme setup', zhTW: '完成主題設定')
                : choosingDarkTheme
                ? L.pick(en: 'Confirm night theme', zhTW: '確定夜間主題')
                : L.pick(en: 'Confirm day theme', zhTW: '確定日間主題'),
            busy: busy,
            backgroundColor: preset.accent,
            foregroundColor: _onColor(preset.accent),
          ),
          _SkipAllButton(onPressed: busy ? null : onSkipAll),
        ],
      ),
    );
  }
}

class _ThemeModeTabs extends StatelessWidget {
  const _ThemeModeTabs({
    required this.choosingDarkTheme,
    required this.lightPreset,
    required this.darkPreset,
    required this.lightThemeConfirmed,
    required this.darkThemeConfirmed,
    required this.reduceMotion,
    required this.onSelectLight,
    required this.onSelectDark,
  });

  final bool choosingDarkTheme;
  final ThemePreset lightPreset;
  final ThemePreset darkPreset;
  final bool lightThemeConfirmed;
  final bool darkThemeConfirmed;
  final bool reduceMotion;
  final VoidCallback onSelectLight;
  final VoidCallback onSelectDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: YanciTheme.glassInputBg,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: YanciTheme.glassBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ThemeModeTab(
              key: const ValueKey('initial-theme-mode-light'),
              label: L.pick(en: 'Day', zhTW: '日間'),
              preset: lightPreset,
              selected: !choosingDarkTheme,
              confirmed: lightThemeConfirmed,
              reduceMotion: reduceMotion,
              onTap: onSelectLight,
            ),
          ),
          Expanded(
            child: _ThemeModeTab(
              key: const ValueKey('initial-theme-mode-dark'),
              label: L.pick(en: 'Night', zhTW: '夜間'),
              preset: darkPreset,
              selected: choosingDarkTheme,
              confirmed: darkThemeConfirmed,
              reduceMotion: reduceMotion,
              onTap: onSelectDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeModeTab extends StatelessWidget {
  const _ThemeModeTab({
    super.key,
    required this.label,
    required this.preset,
    required this.selected,
    required this.confirmed,
    required this.reduceMotion,
    required this.onTap,
  });

  final String label;
  final ThemePreset preset;
  final bool selected;
  final bool confirmed;
  final bool reduceMotion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textColor = selected ? preset.textPrimary : YanciTheme.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      excludeSemantics: true,
      onTap: onTap,
      label: confirmed
          ? L.pick(en: '$label theme confirmed', zhTW: '$label主題已確認')
          : L.pick(en: 'Choose $label theme', zhTW: '選擇$label主題'),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: AnimatedContainer(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              color: selected ? preset.navBarBg : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: selected
                  ? Border.all(color: preset.accent.withValues(alpha: 0.5))
                  : null,
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: preset.gradient),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: preset.accent.withValues(alpha: 0.65),
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: YanciTheme.bodyText.copyWith(
                    color: textColor,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (confirmed) ...[
                  const SizedBox(width: 5),
                  Icon(Icons.check_rounded, size: 15, color: textColor),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.preset, required this.reduceMotion});

  final ThemePreset preset;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final themeName = L.get('theme_preset_${preset.id}');
    return Semantics(
      container: true,
      label: L.pick(en: '$themeName theme preview', zhTW: '$themeName主題預覽'),
      child: AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: _ThemePreviewScene(
          key: ValueKey('initial-theme-preview-${preset.id}'),
          preset: preset,
          themeName: themeName,
        ),
      ),
    );
  }
}

class _ThemePreviewScene extends StatelessWidget {
  const _ThemePreviewScene({
    super.key,
    required this.preset,
    required this.themeName,
  });

  final ThemePreset preset;
  final String themeName;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: preset.gradient,
            ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: preset.accent.withValues(alpha: 0.42),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: preset.accent.withValues(alpha: 0.18),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned(
                right: 22,
                top: 48,
                child: Icon(
                  Icons.auto_awesome,
                  size: 15,
                  color: preset.starColor.withValues(alpha: 0.7),
                ),
              ),
              Positioned(
                right: 52,
                top: 70,
                child: Icon(
                  Icons.auto_awesome,
                  size: 8,
                  color: preset.starColor.withValues(alpha: 0.5),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 15, 18, 14),
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.15,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Holt',
                            style: TextStyle(
                              color: preset.textPrimary,
                              fontFamily: YanciTheme.fontFamily,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 2,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: preset.accent,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: preset.accent.withValues(alpha: 0.5),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      _PreviewBubble(
                        preset: preset,
                        text: L.pick(
                          en: 'Where should we begin today?',
                          zhTW: '今天想從哪裡開始？',
                        ),
                        fromUser: false,
                      ),
                      const SizedBox(height: 9),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _PreviewBubble(
                          preset: preset,
                          text: L.pick(
                            en: 'Stay with me for a while.',
                            zhTW: '先陪我待一會。',
                          ),
                          fromUser: true,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        themeName,
                        key: const ValueKey('initial-theme-preview-name'),
                        style: TextStyle(
                          color: preset.textPrimary,
                          fontFamily: YanciTheme.fontFamily,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        L.get('theme_subtitle_${preset.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: preset.textSecondary,
                          fontFamily: YanciTheme.fontFamily,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 10),
                      YanciBottomNavBar(
                        activeIndex: 2,
                        compact: true,
                        themePreset: preset,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.preset,
    required this.text,
    required this.fromUser,
  });

  final ThemePreset preset;
  final String text;
  final bool fromUser;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: fromUser ? 0.68 : 0.82,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: fromUser ? preset.userBubble : preset.aiBubble,
          gradient: fromUser || preset.aiBubbleTop == null
              ? null
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [preset.aiBubbleTop!, preset.aiBubble],
                ),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: fromUser ? preset.userBubbleBorder : preset.aiBubbleBorder,
          ),
        ),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: preset.textOnBubble,
            fontFamily: YanciTheme.fontFamily,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}

class _ThemeWheel extends StatelessWidget {
  const _ThemeWheel({
    required this.presets,
    required this.controller,
    required this.previewIndex,
    required this.isDarkMode,
    required this.reduceMotion,
    required this.onPreviewChanged,
  });

  final List<ThemePreset> presets;
  final PageController controller;
  final int previewIndex;
  final bool isDarkMode;
  final bool reduceMotion;
  final ValueChanged<int> onPreviewChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: isDarkMode
          ? L.pick(en: 'Night theme preview wheel', zhTW: '夜間主題預覽輪盤')
          : L.pick(en: 'Day theme preview wheel', zhTW: '日間主題預覽輪盤'),
      child: SizedBox(
        height: 92,
        child: PageView.builder(
          key: ValueKey(
            isDarkMode
                ? 'initial-theme-carousel-dark'
                : 'initial-theme-carousel-light',
          ),
          controller: controller,
          clipBehavior: Clip.none,
          physics: const BouncingScrollPhysics(),
          itemCount: presets.length,
          onPageChanged: onPreviewChanged,
          itemBuilder: (context, index) {
            final item = presets[index];
            return AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                var page = previewIndex.toDouble();
                try {
                  if (controller.hasClients) {
                    page = controller.page ?? page;
                  }
                } catch (_) {
                  page = previewIndex.toDouble();
                }
                final difference = (page - index).abs();
                final scale = (1 - difference * 0.24).clamp(0.62, 1.0);
                final opacity = (1 - difference * 0.36).clamp(0.28, 1.0);
                final isPreviewed = difference < 0.5;

                return Center(
                  child: Transform.scale(
                    scale: scale,
                    child: Opacity(
                      opacity: opacity,
                      child: Semantics(
                        button: true,
                        selected: isPreviewed,
                        label: L.pick(
                          en: 'Preview ${L.get('theme_preset_${item.id}')}',
                          zhTW: '預覽${L.get('theme_preset_${item.id}')}',
                        ),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => controller.animateToPage(
                            index,
                            duration: reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 320),
                            curve: Curves.easeOutCubic,
                          ),
                          child: AnimatedContainer(
                            duration: reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 160),
                            width: isPreviewed ? 70 : 52,
                            height: isPreviewed ? 70 : 52,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: item.gradient,
                              ),
                              borderRadius: BorderRadius.circular(
                                isPreviewed ? 21 : 15,
                              ),
                              border: Border.all(
                                color: isPreviewed
                                    ? item.accent
                                    : item.glassBorder.withValues(alpha: 0.8),
                                width: isPreviewed ? 2.5 : 0.8,
                              ),
                              boxShadow: isPreviewed
                                  ? [
                                      BoxShadow(
                                        color: item.accent.withValues(
                                          alpha: 0.42,
                                        ),
                                        blurRadius: 18,
                                        spreadRadius: 2,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Positioned(
                                  top: isPreviewed ? 15 : 11,
                                  left: 8,
                                  child: Container(
                                    width: isPreviewed ? 23 : 17,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: item.aiBubble,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: isPreviewed ? 15 : 11,
                                  right: 8,
                                  child: Container(
                                    width: isPreviewed ? 17 : 13,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: item.userBubble,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
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
    );
  }
}

class _ThemeStartSheet extends StatelessWidget {
  const _ThemeStartSheet({required this.lightPreset, required this.darkPreset});

  final ThemePreset lightPreset;
  final ThemePreset darkPreset;

  @override
  Widget build(BuildContext context) {
    final sheetColor = Color.alphaBlend(
      YanciTheme.surfacePanel,
      YanciTheme.preset.bg1,
    );
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        decoration: BoxDecoration(
          color: sheetColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          border: Border(top: BorderSide(color: YanciTheme.glassBorder)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.pick(en: 'Which one should we begin with?', zhTW: '現在先用哪一種？'),
              key: const ValueKey('initial-theme-start-title'),
              style: YanciTheme.headingMedium.copyWith(
                color: YanciTheme.textPrimary,
                fontSize: 21,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              L.pick(
                en: 'Both are saved. You can switch anytime from Me.',
                zhTW: '兩款都會保存，之後能在「我的」隨時切換。',
              ),
              style: YanciTheme.bodySmall.copyWith(height: 1.5),
            ),
            const SizedBox(height: 18),
            _StartThemeChoice(
              key: const ValueKey('initial-theme-start-light'),
              label: L.pick(en: 'Begin with day', zhTW: '先用日間'),
              preset: lightPreset,
              onTap: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(height: 10),
            _StartThemeChoice(
              key: const ValueKey('initial-theme-start-dark'),
              label: L.pick(en: 'Begin with night', zhTW: '先用夜間'),
              preset: darkPreset,
              onTap: () => Navigator.of(context).pop(true),
            ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(L.pick(en: 'Go back', zhTW: '返回調整')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartThemeChoice extends StatelessWidget {
  const _StartThemeChoice({
    super.key,
    required this.label,
    required this.preset,
    required this.onTap,
  });

  final String label;
  final ThemePreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final themeName = L.get('theme_preset_${preset.id}');
    return Semantics(
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      label: '$label，$themeName',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 82),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                YanciTheme.glassInputBg,
                Color.alphaBlend(
                  YanciTheme.surfacePanel,
                  YanciTheme.preset.bg1,
                ),
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: preset.accent.withValues(alpha: 0.42)),
            ),
            child: Row(
              children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: preset.gradient,
                    ),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: preset.glassBorder),
                  ),
                  child: Center(
                    child: Container(
                      width: 25,
                      height: 9,
                      decoration: BoxDecoration(
                        color: preset.userBubble,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: YanciTheme.bodySmall.copyWith(
                          color: YanciTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        themeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: YanciTheme.bodyText.copyWith(
                          color: YanciTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: preset.accent,
                  size: 21,
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaTitle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final baseStyle = YanciTheme.headingMedium.copyWith(
      color: YanciTheme.textPrimary,
      fontSize: 20,
      fontWeight: FontWeight.w500,
    );
    if (L.locale == 'en') {
      return Text(
        'The one beside you',
        key: const ValueKey('initial-character-title'),
        style: baseStyle.copyWith(fontStyle: FontStyle.italic),
      );
    }
    return Text.rich(
      key: const ValueKey('initial-character-title'),
      TextSpan(
        style: baseStyle,
        children: [
          TextSpan(
            text: L.pick(en: '', zhTW: '與你相伴的那個'),
          ),
          const TextSpan(
            text: 'TA',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

class _SetupLayout extends StatelessWidget {
  const _SetupLayout({
    required this.child,
    required this.topRight,
    required this.bottom,
    this.alignContentToTop = false,
    this.topLeft,
    this.centerAction,
  });

  final Widget child;
  final Widget topRight;
  final Widget bottom;
  final bool alignContentToTop;
  final Widget? topLeft;
  final Widget? centerAction;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      topLeft ?? const SizedBox(width: 48),
                      const Spacer(),
                      topRight,
                    ],
                  ),
                ),
                if (!alignContentToTop) const Spacer(),
                if (alignContentToTop)
                  SizedBox(height: MediaQuery.sizeOf(context).height * 0.072),
                Align(alignment: Alignment.center, child: child),
                if (centerAction != null)
                  Expanded(child: Center(child: centerAction))
                else
                  const Spacer(),
                const SizedBox(height: 24),
                bottom,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SetupTextField extends StatelessWidget {
  const _SetupTextField({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    required this.focusNode,
    required this.textInputAction,
    required this.autofillHints,
    required this.onSubmitted,
    this.autofocus = false,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode focusNode;
  final TextInputAction textInputAction;
  final Iterable<String> autofillHints;
  final ValueChanged<String> onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      style: YanciTheme.bodyText.copyWith(
        color: YanciTheme.textPrimary,
        fontSize: 17,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary,
        ),
        hintStyle: YanciTheme.bodyText.copyWith(
          color: YanciTheme.textSecondary.withValues(alpha: 0.42),
        ),
        filled: true,
        fillColor: YanciTheme.glassInputBg.withValues(alpha: 0.72),
        border: _fieldBorder(),
        enabledBorder: _fieldBorder(),
        focusedBorder: _fieldBorder(color: YanciTheme.accent),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
      ),
    );
  }
}

class _CompactSetupField extends StatelessWidget {
  const _CompactSetupField({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    this.focusNode,
    this.errorText,
    this.onChanged,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '$label${L.get('char_colon')}',
                style: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              textCapitalization: TextCapitalization.sentences,
              style: YanciTheme.bodyText.copyWith(
                color: YanciTheme.textPrimary,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: hint,
                errorText: errorText,
                isDense: true,
                hintStyle: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.42),
                ),
                border: const UnderlineInputBorder(),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.22),
                  ),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: YanciTheme.accent),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: const ValueKey('initial-skip-step'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: YanciTheme.textSecondary,
        minimumSize: const Size(56, 48),
      ),
      child: Text(L.pick(en: 'Skip', zhTW: '跳過')),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('initial-back'),
      onPressed: onPressed,
      tooltip: L.pick(en: 'Back', zhTW: '返回', zhCN: '返回'),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      icon: Icon(
        Icons.arrow_back_rounded,
        size: 22,
        color: YanciTheme.textSecondary,
      ),
    );
  }
}

class _SkipAllButton extends StatelessWidget {
  const _SkipAllButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: const ValueKey('initial-skip-all'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: YanciTheme.textSecondary.withValues(alpha: 0.76),
        minimumSize: const Size(200, 48),
      ),
      child: Text(
        L.pick(en: 'Skip all guidance and explore', zhTW: '無需引導 自我探索'),
        textAlign: TextAlign.center,
        style: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary.withValues(alpha: 0.76),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.busy = false,
    this.backgroundColor,
    this.foregroundColor,
  });

  final VoidCallback? onPressed;
  final String label;
  final bool busy;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final background = backgroundColor ?? YanciTheme.accent;
    final foreground =
        foregroundColor ?? (YanciTheme.isDark ? Colors.black : Colors.white);
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: background.withValues(alpha: 0.45),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
          ),
        ),
        child: busy
            ? SizedBox.square(
                dimension: 19,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: foreground,
                ),
              )
            : Text(
                label,
                style: YanciTheme.bodyText.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

Color _onColor(Color background) {
  return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : const Color(0xFF17151A);
}

OutlineInputBorder _fieldBorder({Color? color}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
    borderSide: BorderSide(
      color: color ?? YanciTheme.glassBorder.withValues(alpha: 0.9),
      width: color == null ? 0.7 : 1.1,
    ),
  );
}
