import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../widgets/starfield_painter.dart';
import '../widgets/neural_field.dart';
import '../widgets/avatar_cropper.dart';
import '../memory/database.dart';
import '../services/settings_manager.dart';
import '../services/token_estimator.dart';
import '../services/sticker_service.dart';
import '../widgets/emotion_panel.dart';

/// 人設卡 — 創建/編輯（存 DB，無行數限制）
class CharacterCardScreen extends StatefulWidget {
  final String? characterId; // null = 新建

  const CharacterCardScreen({super.key, this.characterId});

  @override
  State<CharacterCardScreen> createState() => _CharacterCardScreenState();
}

class _CharacterCardScreenState extends State<CharacterCardScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _raceController = TextEditingController();
  final _skillController = TextEditingController();
  final _ageController = TextEditingController();
  final _heightController = TextEditingController();
  final _genderController = TextEditingController();
  final _relationController = TextEditingController();
  final _drawAnchorUserCtrl = TextEditingController();
  final _drawAnchorCharCtrl = TextEditingController();
  final _drawStyleCtrl = TextEditingController();

  // ═══ Token 計數（緩存門檻提示）═══
  int _descTokens = 0;
  int _staticTotalTokens = 0;
  int _cacheThresholdVal = 1024;
  String _fixedStaticText = ''; // 用戶檔案 + 表情包（本頁不變的部分）
  String? _avatarPath;
  String _ttsVoiceId = '';
  bool _isLoading = true;
  bool _showExtras = false;
  bool _isEditing = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _descController.addListener(_recalcTokens);
    _initTokenCounter();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    if (widget.characterId != null) {
      _isEditing = true;
      final char = await DatabaseHelper.getCharacter(widget.characterId!);
      if (char != null) {
        _nameController.text = char['name'] ?? '';
        _descController.text = char['description'] ?? '';
        _genderController.text = char['gender'] ?? '';
        _relationController.text = char['relationship'] ?? '';
        _raceController.text = char['race'] ?? '';
        _skillController.text = char['skill'] ?? '';
        _ageController.text = char['age'] ?? '';
        _heightController.text = char['height'] ?? '';
        _avatarPath = char['avatar_path'];
        _ttsVoiceId = char['tts_voice_id'] ?? '';
        _drawAnchorUserCtrl.text = char['draw_anchor_user'] ?? '';
        _drawAnchorCharCtrl.text = char['draw_anchor_char'] ?? '';
        _drawStyleCtrl.text = char['draw_style'] ?? '';
        _showExtras =
            _raceController.text.isNotEmpty ||
            _skillController.text.isNotEmpty ||
            _ageController.text.isNotEmpty ||
            _heightController.text.isNotEmpty ||
            _ttsVoiceId.isNotEmpty;
      }
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _initTokenCounter() async {
    // 固定部分：用戶檔案 + 表情包（與 chat_screen 靜態組裝同構）
    final profile = await TokenEstimator.buildProfilePrompt();
    String sticker = '';
    try {
      sticker = await StickerService.buildStickerPrompt(
        characterId: widget.characterId ?? 'default',
      );
    } catch (_) {}
    final parts = <String>[];
    if (profile.isNotEmpty) parts.add(profile);
    if (sticker.isNotEmpty) parts.add(sticker);
    _fixedStaticText = parts.join('\n\n');
    _cacheThresholdVal = await TokenEstimator.cacheThreshold();
    _recalcTokens();
  }

  void _recalcTokens() {
    if (!mounted) return;
    final desc = _descController.text;
    final all = _fixedStaticText.isEmpty ? desc : '$desc\n\n$_fixedStaticText';
    setState(() {
      _descTokens = TokenEstimator.estimate(desc);
      _staticTotalTokens = TokenEstimator.estimate(all);
    });
  }

  /// 輸入框上方的 token 徽章
  Widget _tokenBadge() {
    final ok = _staticTotalTokens >= _cacheThresholdVal;
    final label = L.pick(
      en: 'This card ≈$_descTokens · static total ≈$_staticTotalTokens / cache min $_cacheThresholdVal',
      zhTW:
          '本卡 ≈$_descTokens · 靜態總計 ≈$_staticTotalTokens / 緩存門檻 $_cacheThresholdVal',
    );
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
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

  @override
  void dispose() {
    _descController.removeListener(_recalcTokens);
    _nameController.dispose();
    _descController.dispose();
    _raceController.dispose();
    _skillController.dispose();
    _ageController.dispose();
    _heightController.dispose();
    _genderController.dispose();
    _drawAnchorUserCtrl.dispose();
    _drawAnchorCharCtrl.dispose();
    _drawStyleCtrl.dispose();
    _relationController.dispose();
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
          child: Stack(
            children: [
              Positioned.fill(
                child: YanciTheme.starEnabled
                    ? (YanciTheme.bgEffect == 'stars'
                          ? const StarfieldWidget(starCount: 12)
                          : const NeuralFieldWidget(nodeCount: 16))
                    : const SizedBox.shrink(),
              ),
              SafeArea(
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
                              _isEditing
                                  ? L.get('char_edit_title')
                                  : L.get('char_new_title'),
                              textAlign: TextAlign.center,
                              style: YanciTheme.headingMedium,
                            ),
                          ),
                          // 分享 + 刪除（從角色列表卡片移入；X 入口移去列表）
                          if (widget.characterId != null) ...[
                            IconButton(
                              icon: Icon(
                                Icons.share_outlined,
                                size: 19,
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                              tooltip: L.get('char_share_code'),
                              onPressed: _shareCard,
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                size: 19,
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                              tooltip: L.get('delete'),
                              onPressed: _confirmDeleteCard,
                            ),
                          ] else
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
                          children: [
                            // ═══ 頂部：圖片（左）+ 基本資訊（右）═══
                            SizedBox(
                              height: 220,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: YanciTheme.spacingMd,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // ── 2:3 人設圖片（帶模糊邊緣）──
                                    Padding(
                                      padding: const EdgeInsets.only(top: 24),
                                      child: GestureDetector(
                                        onTap: _pickAvatar,
                                        child: SizedBox(
                                          width: 130,
                                          height: 195,
                                          child:
                                              _avatarPath != null &&
                                                  File(
                                                    _avatarPath!,
                                                  ).existsSync()
                                              ? ShaderMask(
                                                  shaderCallback: (rect) =>
                                                      RadialGradient(
                                                        center:
                                                            Alignment.center,
                                                        radius: 0.85,
                                                        colors: [
                                                          Colors.white,
                                                          Colors.white,
                                                          Colors.white
                                                              .withValues(
                                                                alpha: 0.0,
                                                              ),
                                                        ],
                                                        stops: const [
                                                          0.0,
                                                          0.6,
                                                          1.0,
                                                        ],
                                                      ).createShader(rect),
                                                  blendMode: BlendMode.dstIn,
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          16,
                                                        ),
                                                    child: Image.file(
                                                      File(_avatarPath!),
                                                      fit: BoxFit.cover,
                                                      width: 130,
                                                      height: 195,
                                                    ),
                                                  ),
                                                )
                                              : Container(
                                                  decoration: BoxDecoration(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.08,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          16,
                                                        ),
                                                    border: Border.all(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.1,
                                                          ),
                                                    ),
                                                  ),
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Icon(
                                                        Icons
                                                            .add_photo_alternate_outlined,
                                                        size: 36,
                                                        color: YanciTheme
                                                            .textSecondary
                                                            .withValues(
                                                              alpha: 0.3,
                                                            ),
                                                      ),
                                                      const SizedBox(height: 6),
                                                      Text(
                                                        L.get(
                                                          'char_upload_hint',
                                                        ),
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          color: YanciTheme
                                                              .textSecondary
                                                              .withValues(
                                                                alpha: 0.3,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),

                                    // ── 右側：姓名 / 性別 / 關係（透明氣泡框）──
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.only(top: 24),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 20,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.06,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.1,
                                              ),
                                              width: 0.5,
                                            ),
                                          ),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceEvenly,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              _buildCompactField(
                                                L.get('char_name_label'),
                                                _nameController,
                                                L.get('char_name'),
                                              ),
                                              _buildCompactField(
                                                L.get('char_gender_label'),
                                                _genderController,
                                                L.get('char_gender_hint'),
                                              ),
                                              _buildCompactField(
                                                L.get('char_relation_label'),
                                                _relationController,
                                                L.get('char_relation_hint'),
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
                            const SizedBox(height: YanciTheme.spacingMd),

                            // ═══ Token 計數（緩存門檻提示）═══
                            _tokenBadge(),

                            // ═══ 角色設定（透明氣泡圓角框）═══
                            Stack(
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.1,
                                      ),
                                      width: 0.5,
                                    ),
                                  ),
                                  child: TextField(
                                    controller: _descController,
                                    maxLines: null,
                                    minLines: 6,
                                    style: YanciTheme.bodyText.copyWith(
                                      fontSize: 13,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: L.get('char_desc_hint'),
                                      hintStyle: YanciTheme.bodySmall.copyWith(
                                        color: YanciTheme.textSecondary
                                            .withValues(alpha: 0.3),
                                      ),
                                      border: InputBorder.none,
                                      contentPadding: const EdgeInsets.all(14),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: GestureDetector(
                                    onTap: () => _showExpandedEditor(),
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        color: YanciTheme.accent.withValues(
                                          alpha: 0.1,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Icon(
                                        Icons.open_in_full_rounded,
                                        size: 14,
                                        color: YanciTheme.accent.withValues(
                                          alpha: 0.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: YanciTheme.spacingMd),

                            // ═══ 情緒座標測試面板（kVisible 控制顯隱）═══
                            if (EmotionPanel.kVisible) ...[
                              EmotionPanel(
                                characterId: widget.characterId ?? 'default',
                              ),
                              const SizedBox(height: YanciTheme.spacingMd),
                            ],

                            // 擴展欄位
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _showExtras = !_showExtras),
                              child: Row(
                                children: [
                                  Icon(
                                    _showExtras
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank,
                                    size: 18,
                                    color: YanciTheme.accent,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    L.get('char_more_attr'),
                                    style: YanciTheme.bodySmall.copyWith(
                                      color: YanciTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_showExtras) ...[
                              const SizedBox(height: YanciTheme.spacingMd),
                              _buildField(
                                L.get('char_race'),
                                _raceController,
                                L.get('char_race_hint'),
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              _buildField(
                                L.get('char_skill_label'),
                                _skillController,
                                L.get('char_skill_hint'),
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              _buildField(
                                L.get('char_age'),
                                _ageController,
                                '',
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              _buildField(
                                L.get('char_height_label'),
                                _heightController,
                                '',
                              ),
                              const SizedBox(height: YanciTheme.spacingSm),
                              _buildVoiceIdField(),
                            ],
                            const SizedBox(height: YanciTheme.spacingMd),

                            // ═══ 畫畫角色錨點 ═══
                            _buildDrawAnchorSection(),

                            const SizedBox(height: YanciTheme.spacingXl),

                            // 儲存按鈕
                            SizedBox(
                              width: double.infinity,
                              child: TextButton(
                                onPressed: _isSaving ? null : _save,
                                style: TextButton.styleFrom(
                                  backgroundColor: YanciTheme.accent.withValues(
                                    alpha: 0.15,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      YanciTheme.radiusLg,
                                    ),
                                  ),
                                ),
                                child: _isSaving
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: YanciTheme.accent,
                                        ),
                                      )
                                    : Text(
                                        _nameController.text.isNotEmpty
                                            ? L.fmt('char_ready_named', [
                                                _nameController.text,
                                              ])
                                            : L.get('char_ready'),
                                        style: YanciTheme.bodyText.copyWith(
                                          color: YanciTheme.accent,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: YanciTheme.spacingXl),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController controller,
    String hint,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 50,
          child: Text(
            label,
            style: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildGlassCard(
            child: TextField(
              controller: controller,
              style: YanciTheme.bodyText.copyWith(fontSize: 14),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 右側緊湊型欄位（label + 下劃線輸入）
  Widget _buildCompactField(
    String label,
    TextEditingController controller,
    String hint,
  ) {
    return Row(
      children: [
        Text(
          '$label${L.get('char_colon')}',
          style: TextStyle(
            fontSize: 13,
            color: YanciTheme.textSecondary.withValues(alpha: 0.7),
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            style: YanciTheme.bodyText.copyWith(fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: 12,
                color: YanciTheme.textSecondary.withValues(alpha: 0.3),
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.15),
                ),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: YanciTheme.accent.withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 全螢幕編輯器
  void _showExpandedEditor() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        builder: (ctx, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? const Color(0xF0252228)
                : Colors.white.withValues(alpha: 0.97),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(YanciTheme.radiusLg),
            ),
          ),
          child: Column(
            children: [
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
                  children: [
                    Text(
                      L.get('char_settings'),
                      style: YanciTheme.headingMedium,
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Icon(
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
                    controller: _descController,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: YanciTheme.bodyText.copyWith(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: L.get('char_desc_hint_short'),
                      hintStyle: YanciTheme.bodySmall.copyWith(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.4),
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
  }

  Widget _buildGlassCard({required Widget child}) {
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
            border: Border.all(color: YanciTheme.glassBorder, width: 0.5),
          ),
          child: child,
        ),
      ),
    );
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

    final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.png';
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

  /// 畫畫角色錨點區塊
  Widget _buildDrawAnchorSection() {
    final hasContent =
        _drawAnchorUserCtrl.text.isNotEmpty ||
        _drawAnchorCharCtrl.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() {}), // 始終展開，點擊無效
          child: Row(
            children: [
              Icon(
                Icons.brush_outlined,
                size: 14,
                color: YanciTheme.accent.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 6),
              Text(
                L.pick(en: 'Draw Anchors', zhTW: '畫畫錨點'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: YanciTheme.textSecondary,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
              if (!hasContent) ...[
                const SizedBox(width: 6),
                Text(
                  L.pick(en: '(auto-inject when drawing)', zhTW: '（畫圖時自動注入）'),
                  style: TextStyle(
                    fontSize: 11,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        // User 外觀
        _buildAnchorField(
          label: L.pick(en: 'User appearance', zhTW: '使用者外觀'),
          controller: _drawAnchorUserCtrl,
          hint: 'e.g. short black hair, Asian male, 165cm, casual outfit',
        ),
        const SizedBox(height: 8),
        // Char 外觀
        _buildAnchorField(
          label: L.pick(en: 'Character appearance', zhTW: '角色外觀'),
          controller: _drawAnchorCharCtrl,
          hint: 'e.g. tall woman, dark hair bun, white hoodie, 172cm',
        ),
        const SizedBox(height: 8),
        // 畫風
        _buildAnchorField(
          label: L.pick(en: 'Art style', zhTW: '畫風'),
          controller: _drawStyleCtrl,
          hint: 'e.g. soft anime, watercolor, studio ghibli style',
        ),
      ],
    );
  }

  Widget _buildAnchorField({
    required String label,
    required TextEditingController controller,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            color: YanciTheme.textSecondary.withValues(alpha: 0.6),
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          maxLines: 2,
          minLines: 1,
          style: TextStyle(
            fontSize: 13,
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 12,
              color: YanciTheme.textSecondary.withValues(alpha: 0.3),
              fontFamily: YanciTheme.fontFamily,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: YanciTheme.textSecondary.withValues(alpha: 0.15),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: YanciTheme.textSecondary.withValues(alpha: 0.15),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: YanciTheme.accent.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceIdField() {
    return FutureBuilder<List<String>>(
      future: TtsSettings.getVoiceIdList(),
      builder: (ctx, snap) {
        final voiceIds = snap.data ?? [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              L.pick(en: 'TTS Voice', zhTW: 'TTS 聲音'),
              style: YanciTheme.bodySmall.copyWith(
                color: YanciTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: YanciTheme.glassInputBg,
                borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
              ),
              child: DropdownButton<String>(
                value: _ttsVoiceId.isEmpty ? '' : _ttsVoiceId,
                isExpanded: true,
                underline: const SizedBox(),
                dropdownColor: YanciTheme.isDark
                    ? const Color(0xF0302830)
                    : Colors.white,
                style: YanciTheme.bodyText.copyWith(fontSize: 13),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(
                      L.pick(en: 'Use global', zhTW: '使用全局'),
                      style: TextStyle(
                        fontSize: 13,
                        color: YanciTheme.textSecondary,
                      ),
                    ),
                  ),
                  ...voiceIds.map(
                    (id) => DropdownMenuItem(
                      value: id,
                      child: Text(
                        id.length > 20 ? '${id.substring(0, 20)}…' : id,
                        style: TextStyle(
                          fontSize: 13,
                          color: YanciTheme.isDark
                              ? Colors.white.withValues(alpha: 0.85)
                              : YanciTheme.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _ttsVoiceId = v ?? ''),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _save() async {
    if (_isSaving) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
          content: Text(L.get('char_name_required')),
        ),
      );
      return;
    }
    setState(() => _isSaving = true);

    final id = widget.characterId ?? const Uuid().v4();

    // Only fields owned by this form belong in an edit. In particular, do not
    // rebuild the whole row: characters also contain runtime-managed fields
    // (self_notes, bio_clock, spider-web settings, and future migrations).
    final editableData = <String, dynamic>{
      'name': name,
      'gender': _genderController.text.trim(),
      'relationship': _relationController.text.trim(),
      'description': _descController.text.trim(),
      'race': _raceController.text.trim(),
      'skill': _skillController.text.trim(),
      'age': _ageController.text.trim(),
      'height': _heightController.text.trim(),
      'avatar_path': _avatarPath ?? '',
      'tts_voice_id': _ttsVoiceId,
      'draw_anchor_user': _drawAnchorUserCtrl.text.trim(),
      'draw_anchor_char': _drawAnchorCharCtrl.text.trim(),
      'draw_style': _drawStyleCtrl.text.trim(),
    };

    try {
      if (_isEditing) {
        await DatabaseHelper.updateCharacter(id, editableData);
      } else {
        final now = DateTime.now().toIso8601String();
        await DatabaseHelper.insertCharacter({
          'id': id,
          ...editableData,
          'created_at': now,
          'updated_at': now,
        });
      }
      await UserSettings.saveCharacterName(name);
      await UserSettings.saveActiveCharacterId(id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.pick(en: 'Saved ✓', zhTW: '已保存 ✓')),
            duration: const Duration(milliseconds: 800),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          ),
        );
        Navigator.pop(context, id);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: Colors.red.withValues(alpha: 0.7),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ═══════════════════════════════════
  // 分享（分享碼）＋ 刪除 —— 從角色列表卡片移入
  // ═══════════════════════════════════

  Future<void> _shareCard() async {
    final id = widget.characterId;
    if (id == null) return;
    final c = await DatabaseHelper.getCharacter(id);
    if (c == null || !mounted) return;

    final export = {
      'yanci_character': 1,
      'name': c['name'],
      'gender': c['gender'],
      'relationship': c['relationship'],
      'description': c['description'],
      'race': c['race'],
      'skill': c['skill'],
      'age': c['age'],
      'height': c['height'],
    };
    export.removeWhere((k, v) => v == null || v == '');
    final code = base64Encode(utf8.encode(jsonEncode(export)));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        title: Text(L.get('char_share_code'), style: YanciTheme.headingMedium),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
              ),
              child: SelectableText(
                code,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(L.get('copied_clipboard')),
                    backgroundColor: YanciTheme.accent,
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(milliseconds: 1200),
                    margin: const EdgeInsets.only(
                      bottom: 80,
                      left: 16,
                      right: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
                    ),
                  ),
                );
              },
              child: Text(
                L.get('chat_copy'),
                style: TextStyle(color: YanciTheme.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteCard() async {
    final id = widget.characterId;
    if (id == null) return;
    final c = await DatabaseHelper.getCharacter(id);
    final name = (c?['name'] as String?) ?? '';
    if (!mounted) return;

    final ctrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(L.fmt('char_delete_confirm', [name])),
                const SizedBox(height: 16),
                TextField(
                  controller: ctrl,
                  onChanged: (v) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: L.pick(
                      en: 'Type "$name" to confirm',
                      zhTW: '請輸入 $name 以確認',
                    ),
                    hintStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  L.get('cancel'),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
              ),
              TextButton(
                onPressed: ctrl.text.trim() == name
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: Text(
                  L.get('delete'),
                  style: TextStyle(
                    color: ctrl.text.trim() == name
                        ? Colors.red.withValues(alpha: 0.7)
                        : Colors.grey,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (result == true) {
      await DatabaseHelper.deleteCharacter(id);
      // 刪的是活躍角色時回退 default（沿用列表頁的原邏輯）
      final activeId = await UserSettings.getActiveCharacterId();
      if (id == activeId) {
        await UserSettings.saveActiveCharacterId('default');
      }
      if (!mounted) return;
      Navigator.pop(context); // 返回列表，列表 await 後自動 _load()
    }
  }
}
