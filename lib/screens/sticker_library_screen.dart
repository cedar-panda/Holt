import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../widgets/gradient_background.dart';
import '../services/sticker_service.dart';
import '../memory/database.dart';

/// 表情包庫管理頁 — 上傳 + 三種描述方式 + Vision API
class StickerLibraryScreen extends StatefulWidget {
  final String characterId;

  const StickerLibraryScreen({super.key, this.characterId = 'default'});

  @override
  State<StickerLibraryScreen> createState() => _StickerLibraryScreenState();
}

class _StickerLibraryScreenState extends State<StickerLibraryScreen> {
  List<StickerInfo> _stickers = [];
  bool _isLoading = true;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadStickers();
  }

  Future<void> _loadStickers() async {
    final stickers = widget.characterId == StickerService.userBucket
        ? await StickerService.getUserStickers()
        : await StickerService.getStickers(characterId: widget.characterId);
    setState(() {
      _stickers = stickers;
      _isLoading = false;
    });
  }

  // ═══════════════════════════════════
  // 從相冊上傳
  // ═══════════════════════════════════

  Future<void> _pickAndAdd() async {
    final files = await _picker.pickMultiImage();
    if (files.isEmpty) return;

    for (final file in files) {
      final id = await StickerService.addSticker(
        filePath: file.path,
        characterId: widget.characterId,
      );
      // 上傳後立即打開描述對話框
      if (files.length == 1) {
        if (!mounted) return;
        _showDescribeDialog(id, file.path);
      }
    }

    if (files.length > 1) {
      // 多張上傳，先加入再統一描述
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.fmt('sticker_added_n', [files.length])),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    }
    _loadStickers();
  }

  // ═══════════════════════════════════
  // 三種描述方式對話框
  // ═══════════════════════════════════

  void _showDescribeDialog(int stickerId, String filePath) async {
    int selectedTab = 0; // 0=標籤 1=Vision 2=手動
    final selectedTags = <String>{};
    final lineCtrl = TextEditingController();
    final sceneCtrl = TextEditingController();
    final moodCtrl = TextEditingController();
    bool isVisionLoading = false;
    int visionTokens = 300;
    String? visionError;

    // 加載人設卡列表（Vision 用）
    List<Map<String, dynamic>> visionCharacters = [];
    String? visionSelectedCharId;

    // 找現有描述
    final existing = _stickers.where((s) => s.id == stickerId).toList();
    if (existing.isNotEmpty) {
      final s = existing.first;
      lineCtrl.text = s.line ?? '';
      sceneCtrl.text = s.scene ?? '';
      moodCtrl.text = s.mood ?? '';
      if (s.tags != null) {
        selectedTags.addAll(s.tags!.split(',').map((t) => t.trim()));
      }
    }

    // 預先載入人設卡
    visionCharacters = await DatabaseHelper.getCharacters();
    if (visionCharacters.isNotEmpty) {
      visionSelectedCharId = visionCharacters.first['id'] as String;
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (ctx, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: YanciTheme.surfacePanel,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(YanciTheme.radiusLg),
              ),
            ),
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.all(YanciTheme.spacingMd),
              children: [
                // 拖動條
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: YanciTheme.spacingMd),

                // 預覽圖
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                    child: File(filePath).existsSync()
                        ? Image.file(
                            File(filePath),
                            width: 120,
                            height: 120,
                            cacheWidth: 160,
                            cacheHeight: 160,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.none,
                          )
                        : Container(
                            width: 120,
                            height: 120,
                            color: Colors.grey.withValues(alpha: 0.2),
                            child: const Icon(Icons.broken_image),
                          ),
                  ),
                ),
                const SizedBox(height: YanciTheme.spacingMd),

                // ═══ Tab 切換 ═══
                Row(
                  children: [
                    _tabButton(
                      L.get('sticker_tab_label'),
                      0,
                      selectedTab,
                      (v) => setSheetState(() => selectedTab = v),
                    ),
                    const SizedBox(width: 8),
                    _tabButton(
                      'Vision AI',
                      1,
                      selectedTab,
                      (v) => setSheetState(() => selectedTab = v),
                    ),
                    const SizedBox(width: 8),
                    _tabButton(
                      L.get('sticker_tab_manual'),
                      2,
                      selectedTab,
                      (v) => setSheetState(() => selectedTab = v),
                    ),
                  ],
                ),
                const SizedBox(height: YanciTheme.spacingMd),

                // ═══ Tab 0：選標籤 ═══
                if (selectedTab == 0) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: StickerService.presetLabels.map((label) {
                      final isSelected = selectedTags.contains(label);
                      return GestureDetector(
                        onTap: () {
                          setSheetState(() {
                            isSelected
                                ? selectedTags.remove(label)
                                : selectedTags.add(label);
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? YanciTheme.accent.withValues(alpha: 0.2)
                                : Colors.grey.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected
                                  ? YanciTheme.accent.withValues(alpha: 0.5)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Text(
                            StickerService.tagDisplay(label),
                            style: TextStyle(
                              fontSize: 13,
                              color: isSelected
                                  ? YanciTheme.accent
                                  : YanciTheme.textPrimary,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],

                // ═══ Tab 1：Vision API ═══
                if (selectedTab == 1) ...[
                  // 人設卡選擇
                  if (visionCharacters.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: YanciTheme.accent.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(
                          YanciTheme.radiusSm,
                        ),
                      ),
                      child: DropdownButton<String>(
                        value: visionSelectedCharId,
                        isExpanded: true,
                        underline: const SizedBox(),
                        hint: Text(
                          L.get('sticker_select_char'),
                          style: YanciTheme.bodySmall,
                        ),
                        dropdownColor: YanciTheme.surfacePanel,
                        style: YanciTheme.bodyText.copyWith(fontSize: 13),
                        items: visionCharacters.map((c) {
                          return DropdownMenuItem<String>(
                            value: c['id'] as String,
                            child: Text(c['name'] as String? ?? '?'),
                          );
                        }).toList(),
                        onChanged: (v) =>
                            setSheetState(() => visionSelectedCharId = v),
                      ),
                    ),
                    const SizedBox(height: YanciTheme.spacingSm),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(
                          YanciTheme.radiusSm,
                        ),
                      ),
                      child: Text(
                        L.get('sticker_create_char'),
                        style: YanciTheme.bodySmall.copyWith(
                          color: Colors.orange.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    const SizedBox(height: YanciTheme.spacingSm),
                  ],

                  // Token 數量
                  Row(
                    children: [
                      Text(
                        L.get('sticker_output_token'),
                        style: YanciTheme.bodySmall,
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: YanciTheme.accent.withValues(
                              alpha: 0.6,
                            ),
                            thumbColor: YanciTheme.accent,
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                          ),
                          child: Slider(
                            value: visionTokens.toDouble(),
                            min: 150,
                            max: 500,
                            divisions: 7,
                            onChanged: (v) =>
                                setSheetState(() => visionTokens = v.round()),
                          ),
                        ),
                      ),
                      Text(
                        '$visionTokens',
                        style: YanciTheme.bodySmall.copyWith(
                          color: YanciTheme.accent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: YanciTheme.spacingSm),

                  // 執行按鈕
                  Center(
                    child: TextButton(
                      onPressed:
                          (isVisionLoading || visionSelectedCharId == null)
                          ? null
                          : () async {
                              setSheetState(() {
                                isVisionLoading = true;
                                visionError = null;
                              });
                              try {
                                // 讀取所選人設卡
                                final char = await DatabaseHelper.getCharacter(
                                  visionSelectedCharId!,
                                );
                                final charName =
                                    char?['name'] as String? ??
                                    L.get('sticker_char_fallback');
                                final charPrompt =
                                    char?['description'] as String? ?? '';

                                final result =
                                    await StickerService.describeWithVision(
                                      imagePath: filePath,
                                      characterName: charName,
                                      characterPrompt: charPrompt,
                                      maxTokens: visionTokens,
                                    );
                                setSheetState(() {
                                  lineCtrl.text = result['line'] ?? '';
                                  sceneCtrl.text = result['scene'] ?? '';
                                  moodCtrl.text = result['mood'] ?? '';
                                  isVisionLoading = false;
                                });
                              } catch (e) {
                                setSheetState(() {
                                  visionError = e.toString();
                                  isVisionLoading = false;
                                });
                              }
                            },
                      style: TextButton.styleFrom(
                        backgroundColor: YanciTheme.accent.withValues(
                          alpha: 0.15,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            YanciTheme.radiusLg,
                          ),
                        ),
                      ),
                      child: isVisionLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              L.get('sticker_vision_btn'),
                              style: TextStyle(color: YanciTheme.accent),
                            ),
                    ),
                  ),
                  if (visionError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      visionError!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                  const SizedBox(height: YanciTheme.spacingMd),

                  // 結果欄位（Vision 填完可手動修改）
                  _inputField(
                    L.get('sticker_line'),
                    lineCtrl,
                    L.get('sticker_line_hint'),
                  ),
                  const SizedBox(height: 8),
                  _inputField(
                    L.get('sticker_scene'),
                    sceneCtrl,
                    L.get('sticker_scene_hint'),
                  ),
                  const SizedBox(height: 8),
                  _inputField(
                    L.get('sticker_mood'),
                    moodCtrl,
                    L.get('sticker_mood_hint'),
                  ),
                ],

                // ═══ Tab 2：手動輸入 ═══
                if (selectedTab == 2) ...[
                  _inputField(
                    L.get('sticker_line'),
                    lineCtrl,
                    L.get('sticker_line_manual_hint'),
                  ),
                  const SizedBox(height: 8),
                  _inputField(
                    L.get('sticker_scene'),
                    sceneCtrl,
                    L.get('sticker_scene_manual_hint'),
                  ),
                  const SizedBox(height: 8),
                  _inputField(
                    L.get('sticker_mood'),
                    moodCtrl,
                    L.get('sticker_mood_manual_hint'),
                  ),
                ],

                const SizedBox(height: YanciTheme.spacingLg),

                // ═══ 儲存按鈕 ═══
                Center(
                  child: TextButton(
                    onPressed: () async {
                      final method = ['label', 'vision', 'manual'][selectedTab];
                      final tags = selectedTab == 0
                          ? selectedTags.join(',')
                          : null;

                      await StickerService.updateSticker(
                        stickerId,
                        line: lineCtrl.text.trim().isEmpty
                            ? null
                            : lineCtrl.text.trim(),
                        scene: sceneCtrl.text.trim().isEmpty
                            ? null
                            : sceneCtrl.text.trim(),
                        mood: moodCtrl.text.trim().isEmpty
                            ? null
                            : moodCtrl.text.trim(),
                        tags: tags,
                        descriptionMethod: method,
                      );
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      if (mounted) _loadStickers();
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: YanciTheme.accent.withValues(
                        alpha: 0.15,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          YanciTheme.radiusLg,
                        ),
                      ),
                    ),
                    child: Text(
                      L.get('save'),
                      style: TextStyle(color: YanciTheme.accent),
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

  Widget _tabButton(
    String label,
    int index,
    int current,
    ValueChanged<int> onTap,
  ) {
    final isActive = index == current;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive
                ? YanciTheme.accent.withValues(alpha: 0.15)
                : Colors.grey.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
              color: isActive ? YanciTheme.accent : YanciTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputField(String label, TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      style: YanciTheme.bodyText.copyWith(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: YanciTheme.bodySmall,
        hintText: hint,
        hintStyle: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary.withValues(alpha: 0.3),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }

  // ═══════════════════════════════════
  // 主介面
  // ═══════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // 頂部欄
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
                        L.get('me_sticker'),
                        textAlign: TextAlign.center,
                        style: YanciTheme.headingMedium,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 22,
                        color: YanciTheme.accent,
                      ),
                      onPressed: _pickAndAdd,
                    ),
                  ],
                ),
              ),
              // 表情包網格
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _stickers.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.emoji_emotions_outlined,
                              size: 48,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.3,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              L.get('sticker_empty_hint'),
                              textAlign: TextAlign.center,
                              style: YanciTheme.bodySmall.copyWith(
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(YanciTheme.spacingMd),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: _stickers.length,
                        itemBuilder: (ctx, i) {
                          final s = _stickers[i];
                          return GestureDetector(
                            // 點擊編輯描述
                            onTap: () => _showDescribeDialog(s.id, s.filePath),
                            // 長按刪除
                            onLongPress: () async {
                              final del = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      YanciTheme.radiusMd,
                                    ),
                                  ),
                                  content: Text(
                                    L.get('sticker_delete_confirm'),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: Text(L.get('cancel')),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(c, true),
                                      child: Text(
                                        L.get('delete'),
                                        style: TextStyle(
                                          color: Colors.red.withValues(
                                            alpha: 0.7,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (del == true) {
                                await StickerService.deleteSticker(s.id);
                                _loadStickers();
                              }
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                YanciTheme.radiusSm,
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  File(s.filePath).existsSync()
                                      ? Image.file(
                                          File(s.filePath),
                                          cacheWidth: 128,
                                          cacheHeight: 128,
                                          fit: BoxFit.cover,
                                          filterQuality: FilterQuality.none,
                                        )
                                      : Container(
                                          color: YanciTheme.glassInputBg,
                                          child: Icon(
                                            Icons.broken_image,
                                            color: YanciTheme.textSecondary,
                                          ),
                                        ),
                                  // 描述方式指示
                                  Positioned(
                                    top: 3,
                                    right: 3,
                                    child: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _methodColor(
                                          s.descriptionMethod,
                                        ),
                                      ),
                                    ),
                                  ),
                                  // 台詞預覽
                                  if (s.line != null && s.line!.isNotEmpty)
                                    Positioned(
                                      bottom: 0,
                                      left: 0,
                                      right: 0,
                                      child: Container(
                                        padding: const EdgeInsets.all(3),
                                        color: Colors.black.withValues(
                                          alpha: 0.4,
                                        ),
                                        child: Text(
                                          s.line!,
                                          style: const TextStyle(
                                            fontSize: 9,
                                            color: Colors.white,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _methodColor(String method) {
    switch (method) {
      case 'vision':
        return YanciTheme.accent;
      case 'manual':
        return Colors.blue.withValues(alpha: 0.6);
      default:
        return Colors.green.withValues(alpha: 0.6);
    }
  }
}
