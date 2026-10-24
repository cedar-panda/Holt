import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../memory/database.dart';
import '../models/context_mode.dart';
import '../services/locale_strings.dart';
import '../services/anniversary_service.dart';
import '../services/settings/context_mode_settings.dart';
import '../services/settings_manager.dart';
import '../services/sticker_service.dart';
import '../services/token_estimator.dart';
import '../services/user_persona_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_cropper.dart';
import '../widgets/context_mode_pill.dart';
import '../widgets/gradient_background.dart';
import '../widgets/user_persona_avatar_pair.dart';

/// Mode-aware user role file. Base identity is shared until a mode-specific
/// edit creates an override; the companion binding is shared across modes.
class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key, this.personaId});

  final String? personaId;

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final _nickCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  final _pronounCtrl = TextEditingController();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _loadingFields = false;
  bool _dirty = false;
  bool _hasLoadedInitial = false;
  String? _avatarPath;
  late String _personaId;
  UserPersona? _persona;
  Map<String, dynamic>? _boundCompanion;
  ContextMode _mode = ContextMode.daily;

  int _profileTokens = 0;
  int _staticTotalTokens = 0;
  CacheThresholdInfo _cacheThresholdInfo =
      const CacheThresholdInfo.unavailable();
  String _fixedStaticText = '';

  @override
  void initState() {
    super.initState();
    ContextModeSettings.revision.addListener(_handleContextModeChanged);
    for (final controller in <TextEditingController>[
      _nickCtrl,
      _pronounCtrl,
      _bioCtrl,
    ]) {
      controller.addListener(_handleFieldChanged);
    }
    _loadInitial();
  }

  void _handleContextModeChanged() {
    if (!mounted || !_hasLoadedInitial) return;
    unawaited(_syncEffectiveMode());
  }

  Future<void> _syncEffectiveMode() async {
    final characterId = await UserSettings.getActiveCharacterId();
    if (characterId.isEmpty) return;
    final nextMode = await ContextModeSettings.effectiveMode(characterId);
    if (!mounted || nextMode == _mode) return;
    await _switchMode(nextMode);
  }

  void _handleFieldChanged() {
    if (!_loadingFields) _dirty = true;
    _recalcTokens();
  }

  Future<void> _loadInitial() async {
    final selected = await UserPersonaService.selectedPersona();
    _personaId = widget.personaId?.trim().isNotEmpty == true
        ? widget.personaId!.trim()
        : selected.id;
    final characterId = await UserSettings.getActiveCharacterId();
    _mode = characterId.isEmpty
        ? ContextMode.daily
        : await ContextModeSettings.effectiveMode(characterId);
    await _loadMode();
    await _initTokenCounter();
    _hasLoadedInitial = true;
    if (mounted) unawaited(_syncEffectiveMode());
  }

  Future<void> _loadMode() async {
    final persona =
        await UserPersonaService.personaForMode(_personaId, _mode) ??
        await UserPersonaService.ensureDefaultPersona();
    final companionId = await UserPersonaService.companionIdForPersona(
      personaId: persona.id,
      contextMode: _mode,
    );
    final companion = companionId == null
        ? null
        : await DatabaseHelper.getCharacter(companionId);
    if (!mounted) return;
    _loadingFields = true;
    _nickCtrl.text = persona.displayName;
    _pronounCtrl.text = persona.pronouns;
    _bioCtrl.text = persona.bio;
    _loadingFields = false;
    setState(() {
      _personaId = persona.id;
      _persona = persona;
      _avatarPath = persona.avatarPath.isEmpty ? null : persona.avatarPath;
      _boundCompanion = companion;
      _dirty = false;
      _isLoading = false;
    });
  }

  Future<void> _initTokenCounter() async {
    final charId = await UserSettings.getActiveCharacterId();
    final guide = await UserPersonaService.profileGuide(_personaId, _mode);
    final character = await DatabaseHelper.getCharacter(charId);
    final characterDescription =
        character?['description']?.toString().trim() ?? '';
    String sticker = '';
    try {
      sticker = await StickerService.buildStickerPrompt(characterId: charId);
    } catch (_) {}
    _fixedStaticText = [
      characterDescription,
      guide,
      sticker,
    ].where((text) => text.isNotEmpty).join('\n\n');
    _cacheThresholdInfo = await TokenEstimator.cacheThresholdInfo();
    await _recalcTokens();
  }

  Future<void> _recalcTokens() async {
    final profile = await TokenEstimator.buildProfilePrompt(
      nickname: _nickCtrl.text.trim(),
      pronouns: _pronounCtrl.text.trim(),
      bio: _bioCtrl.text.trim(),
    );
    if (!mounted) return;
    final all = [
      _fixedStaticText,
      profile,
    ].where((text) => text.isNotEmpty).join('\n\n');
    setState(() {
      _profileTokens = TokenEstimator.estimate(profile);
      _staticTotalTokens = TokenEstimator.estimate(all);
    });
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 90,
    );
    if (picked == null) return;
    final appDir = await getApplicationDocumentsDirectory();
    final avatarDir = Directory('${appDir.path}/avatars');
    if (!avatarDir.existsSync()) avatarDir.createSync(recursive: true);
    final outputPath =
        '${avatarDir.path}/user_avatar_${DateTime.now().millisecondsSinceEpoch}.png';
    if (!mounted) return;
    final croppedPath = await AvatarCropperScreen.show(
      context,
      imageFile: File(picked.path),
      outputPath: outputPath,
    );
    if (croppedPath == null || !mounted) return;
    setState(() {
      _avatarPath = croppedPath;
      _dirty = true;
    });
  }

  Future<void> _save({bool showNotice = true}) async {
    if (_isSaving || !_dirty) return;
    setState(() => _isSaving = true);
    try {
      await UserPersonaService.saveModeIdentity(
        personaId: _personaId,
        contextMode: _mode,
        displayName: _nickCtrl.text,
        pronouns: _pronounCtrl.text,
        bio: _bioCtrl.text,
        avatarPath: _avatarPath ?? '',
      );
      await UserPersonaService.selectPersona(_personaId);
      _dirty = false;
      if (mounted && showNotice) {
        showThemedPillNotice(context, L.get('saved'));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _switchMode(ContextMode mode) async {
    if (mode == _mode) return;
    await _save(showNotice: false);
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _isLoading = true;
    });
    await _loadMode();
    await _initTokenCounter();
  }

  Future<void> _requestDeletePersona() async {
    final personas = await UserPersonaService.listPersonas();
    if (!mounted) return;
    if (personas.length <= 1) {
      showThemedPillNotice(
        context,
        L.pick(
          en: 'Keep at least one identity',
          zhTW: '至少需要保留一個身分',
          zhCN: '至少需要保留一个身份',
        ),
      );
      return;
    }
    final nickname = _nickCtrl.text.trim();
    final expectedName = nickname.isEmpty
        ? L.pick(en: 'Unnamed identity', zhTW: '未命名身分', zhCN: '未命名身份')
        : nickname;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeletePersonaDialog(expectedName: expectedName),
    );
    if (confirmed != true) return;
    final archived = await UserPersonaService.archivePersona(_personaId);
    if (!mounted) return;
    if (!archived) {
      showThemedPillNotice(
        context,
        L.pick(
          en: 'This identity could not be deleted',
          zhTW: '無法刪除這個身分',
          zhCN: '无法删除这个身份',
        ),
      );
      return;
    }
    await AnniversaryService.deleteForPersona(_personaId);
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _selectCompanion() async {
    await _save(showNotice: false);
    final characters = await DatabaseHelper.getCharacters();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _CompanionPickerSheet(
        characters: characters,
        selectedId: _boundCompanion?['id']?.toString(),
      ),
    );
    if (selected == null) return;
    if (selected.isEmpty) {
      await UserPersonaService.unbindCompanionForPersona(
        personaId: _personaId,
        contextMode: _mode,
      );
    } else {
      await UserPersonaService.bindSingleCompanion(
        personaId: _personaId,
        characterId: selected,
        contextMode: _mode,
      );
    }
    await _loadMode();
  }

  Future<void> _handleBack() async {
    await _save(showNotice: false);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    ContextModeSettings.revision.removeListener(_handleContextModeChanged);
    _nickCtrl.dispose();
    _bioCtrl.dispose();
    _pronounCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: GradientBackground(
            child: SafeArea(
              child: Column(
                children: [
                  _buildHeader(),
                  Expanded(
                    child: _isLoading || _persona == null
                        ? const Center(child: CircularProgressIndicator())
                        : SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(
                              horizontal: YanciTheme.spacingMd,
                            ),
                            child: Column(
                              children: [
                                _buildIdentityHeader(),
                                const SizedBox(height: YanciTheme.spacingMd),
                                _tokenBadge(),
                                _buildBioCard(),
                                const SizedBox(height: 28),
                              ],
                            ),
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

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: YanciTheme.spacingSm,
        vertical: YanciTheme.spacingXs,
      ),
      child: SizedBox(
        height: 98,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 48,
                  child: Center(
                    child: Text(
                      L.get('profile_title'),
                      style: YanciTheme.headingMedium,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ContextModePill(
                  mode: _mode,
                  onChanged: _switchMode,
                  compact: true,
                ),
              ],
            ),
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_rounded,
                  size: 20,
                  color: YanciTheme.textPrimary,
                ),
                onPressed: _handleBack,
              ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                key: const ValueKey('delete-user-persona'),
                tooltip: L.pick(
                  en: 'Delete identity',
                  zhTW: '刪除身分',
                  zhCN: '删除身份',
                ),
                onPressed: _requestDeletePersona,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: contextRpColor.withValues(alpha: .72),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdentityHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YanciTheme.spacingMd,
        8,
        YanciTheme.spacingMd,
        12,
      ),
      child: Column(
        children: [
          Center(
            child: UserPersonaAvatarPair(
              // CLAUDE MOTION HANDOFF: tune only the pair transition in
              // user_persona_avatar_pair.dart; state stays on this screen.
              key: ValueKey('profile-pair-$_personaId-${_mode.storageValue}'),
              persona: _persona!.copyWith(avatarPath: _avatarPath ?? ''),
              companion: _boundCompanion,
              size: 96,
              onUserAvatarTap: _pickAvatar,
              onBindingTap: _selectCompanion,
            ),
          ),
          const SizedBox(height: 30),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _compactField(
                  L.get('profile_name'),
                  _nickCtrl,
                  L.pick(
                    en: 'How should they address you?',
                    zhTW: 'TA 怎麼稱呼你',
                    zhCN: 'TA 怎么称呼你',
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: _compactField(
                  L.get('profile_pronoun'),
                  _pronounCtrl,
                  L.pick(
                    en: 'he / she / they / …',
                    zhTW: '他 / 她 / …',
                    zhCN: '他 / 她 / …',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _compactField(
    String label,
    TextEditingController controller,
    String hint,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: YanciTheme.bodySmall.copyWith(
            color: YanciTheme.textSecondary,
            fontSize: 11,
          ),
        ),
        TextField(
          controller: controller,
          style: YanciTheme.bodyText.copyWith(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: .34),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: YanciTheme.glassBorder),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: YanciTheme.accent, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBioCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        constraints: const BoxConstraints(minHeight: 160, maxHeight: 260),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: YanciTheme.glassBorder, width: 1),
        ),
        child: TextField(
          controller: _bioCtrl,
          maxLines: null,
          minLines: 6,
          style: YanciTheme.bodyText.copyWith(fontSize: 13),
          decoration: InputDecoration(
            labelText: L.get('profile_bio'),
            hintText: L.pick(
              en: 'Tell them who you are.\nThat is where the story begins.',
              zhTW: '告訴 TA 你是誰\n故事會從這裡開始',
              zhCN: '告诉 TA 你是谁\n故事会从这里开始',
            ),
            labelStyle: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary,
            ),
            hintStyle: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: .3),
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.all(14),
          ),
        ),
      ),
    );
  }

  Widget _tokenBadge() {
    final ok = _cacheThresholdInfo.isEligibleAt(_staticTotalTokens);
    final thresholdLabel = TokenEstimator.localizedCacheThresholdLabel(
      _cacheThresholdInfo,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6),
      child: Row(
        children: [
          Icon(
            ok ? Icons.bolt_outlined : Icons.info_outline,
            size: 12,
            color: ok
                ? YanciTheme.accent
                : YanciTheme.textSecondary.withValues(alpha: .5),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              L.pick(
                en: 'File ≈$_profileTokens · static total ≈$_staticTotalTokens / $thresholdLabel',
                zhTW:
                    '檔案 ≈$_profileTokens · 靜態總計 ≈$_staticTotalTokens / $thresholdLabel',
                zhCN:
                    '档案 ≈$_profileTokens · 静态总计 ≈$_staticTotalTokens / $thresholdLabel',
              ),
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: ok
                    ? YanciTheme.accent.withValues(alpha: .8)
                    : YanciTheme.textSecondary.withValues(alpha: .6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeletePersonaDialog extends StatefulWidget {
  const _DeletePersonaDialog({required this.expectedName});

  final String expectedName;

  @override
  State<_DeletePersonaDialog> createState() => _DeletePersonaDialogState();
}

class _DeletePersonaDialogState extends State<_DeletePersonaDialog> {
  final _controller = TextEditingController();
  bool _matches = false;

  void _check(String value) {
    final matches = value == widget.expectedName;
    if (_matches != matches) setState(() => _matches = matches);
  }

  void _confirm() {
    if (_matches) Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: YanciTheme.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        L.pick(en: 'Delete identity', zhTW: '刪除身分', zhCN: '删除身份'),
        style: YanciTheme.headingMedium,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L.pick(
              en: 'Enter “${widget.expectedName}” to confirm deletion.',
              zhTW: '請輸入「${widget.expectedName}」確認刪除',
              zhCN: '请输入「${widget.expectedName}」确认删除',
            ),
            style: YanciTheme.bodyText,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('delete-persona-name-field'),
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: _check,
            onSubmitted: (_) => _confirm(),
            decoration: InputDecoration(
              hintText: widget.expectedName,
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: YanciTheme.glassBorder),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: contextRpColor, width: 1.2),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(L.get('cancel')),
        ),
        TextButton(
          key: const ValueKey('confirm-delete-persona'),
          onPressed: _matches ? _confirm : null,
          child: Text(
            L.pick(en: 'Delete', zhTW: '刪除', zhCN: '删除'),
            style: TextStyle(
              color: _matches
                  ? contextRpColor
                  : YanciTheme.textSecondary.withValues(alpha: .35),
              fontFamily: YanciTheme.fontFamily,
            ),
          ),
        ),
      ],
    );
  }
}

class _CompanionPickerSheet extends StatelessWidget {
  const _CompanionPickerSheet({
    required this.characters,
    required this.selectedId,
  });

  final List<Map<String, dynamic>> characters;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: YanciTheme.surfacePanel.withValues(alpha: .94),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .62,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 34,
                    height: 3,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: .2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      L.pick(
                        en: 'Bind a character',
                        zhTW: '綁定角色',
                        zhCN: '绑定角色',
                      ),
                      style: YanciTheme.headingMedium,
                    ),
                  ),
                  if (selectedId != null)
                    ListTile(
                      leading: const Icon(Icons.link_off_rounded),
                      title: Text(
                        L.pick(
                          en: 'Remove binding',
                          zhTW: '解除綁定',
                          zhCN: '解除绑定',
                        ),
                      ),
                      onTap: () => Navigator.pop(context, ''),
                    ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: characters.length,
                      itemBuilder: (context, index) {
                        final character = characters[index];
                        final id = character['id']?.toString() ?? '';
                        final path = character['avatar_path']?.toString() ?? '';
                        final hasImage =
                            path.isNotEmpty && File(path).existsSync();
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: YanciTheme.accent.withValues(
                              alpha: .09,
                            ),
                            backgroundImage: hasImage
                                ? FileImage(File(path))
                                : null,
                            child: hasImage
                                ? null
                                : Icon(
                                    Icons.favorite_outline_rounded,
                                    color: YanciTheme.accent.withValues(
                                      alpha: .5,
                                    ),
                                  ),
                          ),
                          title: Text(character['name']?.toString() ?? ''),
                          trailing: id == selectedId
                              ? Icon(
                                  Icons.check_rounded,
                                  color: YanciTheme.accent,
                                )
                              : null,
                          onTap: () => Navigator.pop(context, id),
                        );
                      },
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
}
