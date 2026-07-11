import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/sticker_service.dart';
import '../widgets/avatar_cropper.dart';

/// 用戶檔案 — 頭像、暱稱、偏好、自訂資訊
class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key});

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final _nickCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  final _pronounCtrl = TextEditingController();
  bool _isLoading = true;
  String? _avatarPath;

  // ═══ Token 計數（緩存門檻提示）═══
  int _profileTokens = 0;
  int _staticTotalTokens = 0;
  int _cacheThresholdVal = 1024;
  String _fixedStaticText = ''; // 人設卡 + 表情包（本頁不變的部分）

  @override
  void initState() {
    super.initState();
    _nickCtrl.addListener(_recalcTokens);
    _pronounCtrl.addListener(_recalcTokens);
    _bioCtrl.addListener(_recalcTokens);
    _load().then((_) => _initTokenCounter());
  }

  Future<void> _initTokenCounter() async {
    // 固定部分：當前人設卡 + 表情包
    final desc = await ApiSettings.getSystemPrompt();
    final charId = await UserSettings.getActiveCharacterId();
    String sticker = '';
    try {
      sticker = await StickerService.buildStickerPrompt(characterId: charId);
    } catch (_) {}
    final parts = <String>[desc];
    if (sticker.isNotEmpty) parts.add(sticker);
    _fixedStaticText = parts.join('\n\n');
    _cacheThresholdVal = await TokenEstimator.cacheThreshold();
    _recalcTokens();
  }

  Future<void> _recalcTokens() async {
    final profile = await TokenEstimator.buildProfilePrompt(
      nickname: _nickCtrl.text.trim(),
      pronouns: _pronounCtrl.text.trim(),
      bio: _bioCtrl.text.trim(),
    );
    if (!mounted) return;
    final all = profile.isEmpty
        ? _fixedStaticText
        : '$_fixedStaticText\n\n$profile';
    setState(() {
      _profileTokens = TokenEstimator.estimate(profile);
      _staticTotalTokens = TokenEstimator.estimate(all);
    });
  }

  /// 輸入框上方的 token 徽章
  Widget _tokenBadge() {
    final ok = _staticTotalTokens >= _cacheThresholdVal;
    final label = L.pick(
      en: 'Profile ≈$_profileTokens · static total ≈$_staticTotalTokens / cache min $_cacheThresholdVal',
      zhTW:
          '檔案 ≈$_profileTokens · 靜態總計 ≈$_staticTotalTokens / 緩存門檻 $_cacheThresholdVal',
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
                : YanciTheme.textSecondary.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              style: YanciTheme.bodySmall.copyWith(
                fontSize: 10,
                color: ok
                    ? YanciTheme.accent.withValues(alpha: 0.8)
                    : YanciTheme.textSecondary.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _load() async {
    _nickCtrl.text = await UserSettings.getUserName();
    _bioCtrl.text = await UserSettings.getUserBio();
    _pronounCtrl.text = await UserSettings.getUserPronouns();
    _avatarPath = await UserSettings.getUserAvatarPath();
    if (_avatarPath != null && _avatarPath!.isEmpty) _avatarPath = null;
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 90,
    );
    if (picked == null) return;

    final appDir = await getApplicationDocumentsDirectory();
    final avatarDir = Directory('${appDir.path}/avatars');
    if (!avatarDir.existsSync()) avatarDir.createSync(recursive: true);

    final ext = '.png'; // cropper 輸出 png
    final fileName = 'user_avatar_${DateTime.now().millisecondsSinceEpoch}$ext';
    final outputPath = '${avatarDir.path}/$fileName';

    if (!mounted) return;
    final croppedPath = await AvatarCropperScreen.show(
      context,
      imageFile: File(picked.path),
      outputPath: outputPath,
    );

    if (croppedPath != null) {
      if (!mounted) return;
      setState(() => _avatarPath = croppedPath);
    }
  }

  Future<void> _save() async {
    await UserSettings.saveUserName(_nickCtrl.text.trim());
    await UserSettings.saveUserBio(_bioCtrl.text.trim());
    await UserSettings.saveUserPronouns(_pronounCtrl.text.trim());
    await UserSettings.saveUserAvatarPath(_avatarPath ?? '');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.get('saved')),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _nickCtrl.dispose();
    _bioCtrl.dispose();
    _pronounCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: GradientBackground(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: YanciTheme.spacingSm,
                    vertical: YanciTheme.spacingXs,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios_rounded,
                          size: 20,
                          color: YanciTheme.textPrimary,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Text(
                          L.get('profile_title'),
                          textAlign: TextAlign.center,
                          style: YanciTheme.headingMedium,
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: YanciTheme.spacingMd,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: YanciTheme.spacingMd),

                        // ═══ 頭像 ═══
                        Center(
                          child: GestureDetector(
                            onTap: _pickAvatar,
                            child: Stack(
                              children: [
                                Container(
                                  width: 88,
                                  height: 88,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.08,
                                    ),
                                    border: Border.all(
                                      color: YanciTheme.accent.withValues(
                                        alpha: 0.2,
                                      ),
                                      width: 2,
                                    ),
                                    image:
                                        _avatarPath != null &&
                                            File(_avatarPath!).existsSync()
                                        ? DecorationImage(
                                            image: FileImage(
                                              File(_avatarPath!),
                                            ),
                                            fit: BoxFit.cover,
                                          )
                                        : null,
                                  ),
                                  child:
                                      _avatarPath == null ||
                                          !File(_avatarPath!).existsSync()
                                      ? Icon(
                                          Icons.person_rounded,
                                          size: 40,
                                          color: YanciTheme.accent.withValues(
                                            alpha: 0.35,
                                          ),
                                        )
                                      : null,
                                ),
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: YanciTheme.accent,
                                      border: Border.all(
                                        color: YanciTheme.isDark
                                            ? Colors.black.withValues(
                                                alpha: 0.3,
                                              )
                                            : Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.camera_alt_rounded,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: YanciTheme.spacingLg),
                        Text(
                          L.get('profile_name'),
                          style: YanciTheme.bodySmall.copyWith(
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _field(
                          _nickCtrl,
                          L.pick(
                            en: 'How should they address you?',
                            zhTW: 'TA 怎麼稱呼你',
                          ),
                        ),
                        const SizedBox(height: YanciTheme.spacingMd),

                        Text(
                          L.get('profile_pronoun'),
                          style: YanciTheme.bodySmall.copyWith(
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _field(
                          _pronounCtrl,
                          L.pick(en: 'he / she / they / …', zhTW: '他/她/…'),
                        ),
                        const SizedBox(height: YanciTheme.spacingMd),

                        Text(
                          L.get('profile_bio'),
                          style: YanciTheme.bodySmall.copyWith(
                            color: YanciTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _tokenBadge(),
                        _multiField(
                          _bioCtrl,
                          L.pick(
                            en: 'Tell them who you are.\nThat is where the story begins.',
                            zhTW: '告訴TA你是誰。\n填了才有故事～',
                          ),
                        ),
                        const SizedBox(height: YanciTheme.spacingXl),

                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: _save,
                            style: TextButton.styleFrom(
                              backgroundColor: YanciTheme.accent.withValues(
                                alpha: 0.15,
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  YanciTheme.radiusLg,
                                ),
                              ),
                            ),
                            child: Text(
                              L.get('save'),
                              style: YanciTheme.bodyText.copyWith(
                                color: YanciTheme.accent,
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

  Widget _field(TextEditingController ctrl, String hint) {
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
          ),
          child: TextField(
            controller: ctrl,
            style: YanciTheme.bodyText.copyWith(fontSize: 14),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.4),
              ),
              border: InputBorder.none,
            ),
          ),
        ),
      ),
    );
  }

  Widget _multiField(TextEditingController ctrl, String hint) {
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
          ),
          child: TextField(
            controller: ctrl,
            maxLines: null,
            minLines: 4,
            style: YanciTheme.bodyText.copyWith(fontSize: 14),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary.withValues(alpha: 0.4),
              ),
              border: InputBorder.none,
            ),
          ),
        ),
      ),
    );
  }
}
