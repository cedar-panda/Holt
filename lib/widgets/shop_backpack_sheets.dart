import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../memory/database.dart';
import '../services/marriage_service.dart';
import '../services/settings_manager.dart';
import '../services/shop_service.dart';
import '../services/image_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import 'marriage_cert_card.dart';
import 'pixel_art_editor.dart';

// ════════════════════════════════════════════════════════════════════
// 商店 Bottom Sheet
// ════════════════════════════════════════════════════════════════════

/// giftPending：聊天內送禮——僅扣款，物品掛起隨下一條消息送出
enum ShopMode { normal, giftToChar, giftPending }

class ShopBottomSheet extends StatefulWidget {
  final ShopMode mode;
  final String? targetCharId;
  final String? pendingScopeId;

  /// giftPending 模式：durable reservation 建立後回傳聊天頁。
  final void Function(PendingGiftReservation reservation)? onGiftPending;

  /// 非空 → 商店名下方顯示「邀請 XX 一起逛」膠囊（聊天內打開時傳入角色名）
  final String? inviteCharName;

  /// 膠囊點擊回調（sheet 會先自行關閉再回調）
  final VoidCallback? onInviteBrowse;

  const ShopBottomSheet({
    super.key,
    this.mode = ShopMode.normal,
    this.targetCharId,
    this.pendingScopeId,
    this.onGiftPending,
    this.inviteCharName,
    this.onInviteBrowse,
  });

  @override
  State<ShopBottomSheet> createState() => _ShopBottomSheetState();
}

class _ShopBottomSheetState extends State<ShopBottomSheet>
    with SingleTickerProviderStateMixin {
  List<ShopItem> _items = [];
  bool _isLoading = true;
  late AnimationController _staggerController;

  @override
  void initState() {
    super.initState();
    _staggerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _loadItems();
  }

  @override
  void dispose() {
    _staggerController.dispose();
    super.dispose();
  }

  Future<void> _loadItems() async {
    final items = await ShopService.getShopItems();
    if (!mounted) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });
    _staggerController.forward(from: 0);
  }

  Future<void> _addNewItem() async {
    final picker = ImagePicker();
    final xFile = await picker.pickImage(source: ImageSource.gallery);
    if (xFile == null) return;
    await _processNewItem(xFile.path);
  }

  Future<void> _openPixelArtEditor() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const PixelArtEditor(),
    );
    if (result != null && result.isNotEmpty) {
      await _processNewItem(result);
    }
  }

  Future<void> _processNewItem(String imagePath) async {
    final nameController = TextEditingController();
    final priceController = TextEditingController(text: '100');
    bool autoRemoveBackground = false;

    if (!mounted) return;

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => _ThemedDialog(
          title: L.pick(en: 'Upload new item', zhTW: '上傳新商品'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: YanciTheme.accent.withValues(alpha: 0.3),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.none,
                ),
              ),
              const SizedBox(height: 16),
              _ThemedTextField(
                controller: nameController,
                hint: L.pick(en: 'Item name', zhTW: '商品名稱'),
              ),
              const SizedBox(height: 8),
              _ThemedTextField(
                controller: priceController,
                hint: L.pick(en: 'Shell price', zhTW: '貝殼價格'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Checkbox(
                    value: autoRemoveBackground,
                    onChanged: (v) =>
                        setStateDialog(() => autoRemoveBackground = v ?? false),
                    activeColor: YanciTheme.accent,
                  ),
                  Text(
                    L.pick(
                      en: 'Remove background automatically (white to transparent)',
                      zhTW: '自動去背（白底轉透明）',
                    ),
                    style: TextStyle(
                      color: YanciTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ],
          ),
          confirmLabel: L.pick(en: 'Add', zhTW: '新增'),
          onConfirm: () => Navigator.of(ctx).pop(true),
          onCancel: () => Navigator.of(ctx).pop(false),
        ),
      ),
    );

    if (confirm == true) {
      final finalName = nameController.text.trim().isEmpty
          ? L.pick(en: 'Custom item', zhTW: '自定義商品')
          : nameController.text.trim();
      setState(() => _isLoading = true);

      String finalImagePath = imagePath;
      if (autoRemoveBackground) {
        final processedPath = await ImageService.removeWhiteBackground(
          imagePath,
        );
        if (processedPath != null) {
          finalImagePath = processedPath;
        }
      }

      await ShopService.addShopItem(
        name: finalName,
        description: '',
        price: int.tryParse(priceController.text) ?? 100,
        type: 'non_consumable',
        category: '預設',
        sortOrder: 0,
        imageSourcePath: finalImagePath,
      );
      await _loadItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: YanciTheme.surfacePanel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: YanciTheme.accent.withValues(alpha: 0.08),
            blurRadius: 30,
            spreadRadius: -5,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Drag handle ──
          _buildDragHandle(),
          // ── Gradient accent line ──
          Container(
            height: 1.5,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  YanciTheme.accent.withValues(alpha: 0.5),
                  YanciTheme.accentLight.withValues(alpha: 0.3),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          // ── Header ──
          ClipRRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 14, 16, 14),
                color: YanciTheme.glassInputBg.withValues(alpha: 0.3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.storefront_rounded,
                              color: YanciTheme.accent,
                              size: 22,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              L.pick(en: 'Shell Shop', zhTW: '貝殼商店'),
                              style: YanciTheme.headingMedium.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        // ═══ 邀請同逛膠囊（聊天內打開時顯示）═══
                        if (widget.inviteCharName != null &&
                            widget.onInviteBrowse != null) ...[
                          const SizedBox(height: 6),
                          GestureDetector(
                            onTap: () {
                              final cb = widget.onInviteBrowse;
                              Navigator.of(context).pop();
                              cb?.call();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: YanciTheme.accent.withValues(
                                  alpha: 0.10,
                                ),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: YanciTheme.accent.withValues(
                                    alpha: 0.30,
                                  ),
                                  width: 0.6,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.group_add_rounded,
                                    size: 13,
                                    color: YanciTheme.accent.withValues(
                                      alpha: 0.9,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    L.pick(
                                      en: 'Invite ${widget.inviteCharName} to browse together',
                                      zhTW:
                                          '邀請 ${widget.inviteCharName} 一起逛',
                                    ),
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: YanciTheme.accent.withValues(
                                        alpha: 0.9,
                                      ),
                                      fontFamily: YanciTheme.fontFamily,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Row(
                      children: [
                        _HeaderIconButton(
                          icon: Icons.brush_rounded,
                          tooltip: L.pick(en: 'Canvas', zhTW: '畫布'),
                          onPressed: _openPixelArtEditor,
                        ),
                        const SizedBox(width: 6),
                        _HeaderIconButton(
                          icon: Icons.add_photo_alternate_outlined,
                          tooltip: L.pick(
                            en: 'Upload custom pixel art',
                            zhTW: '上傳自定義像素圖',
                          ),
                          onPressed: _addNewItem,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ── Content ──
          Expanded(
            child: _isLoading
                ? Center(
                    child: CircularProgressIndicator(color: YanciTheme.accent),
                  )
                : _items.isEmpty
                ? _EmptyState(
                    icon: Icons.storefront_rounded,
                    text: L.pick(
                      en: 'No items yet.\nUse the top-right button to upload your pixel art!',
                      zhTW: '目前沒有商品哦\n點擊右上角上傳你畫的像素圖！',
                    ),
                  )
                : AnimatedBuilder(
                    animation: _staggerController,
                    builder: (_, _) => GridView.builder(
                      padding: const EdgeInsets.all(20),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 0.72,
                            crossAxisSpacing: 14,
                            mainAxisSpacing: 18,
                          ),
                      itemCount: _items.length,
                      itemBuilder: (ctx, i) {
                        final delay = (i / _items.length).clamp(0.0, 1.0);
                        final t = Curves.easeOut.transform(
                          ((_staggerController.value - delay * 0.5) /
                                  (1.0 - delay * 0.5))
                              .clamp(0.0, 1.0),
                        );
                        return Opacity(
                          opacity: t,
                          child: Transform.scale(
                            scale: 0.85 + 0.15 * t,
                            child: _ShopItemCard(
                              item: _items[i],
                              onBuy: () => _handleBuy(_items[i]),
                              onDelete: () => _handleDelete(_items[i]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleBuy(ShopItem item) async {
    // ═══ 聊天送禮：僅扣款 → 掛起，發送時才入對方背包，取消可退 ═══
    if (widget.mode == ShopMode.giftPending) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => _ThemedDialog(
          title: L.pick(en: 'Confirm gift', zhTW: '送禮確認'),
          content: Text(
            L.pick(
              en: 'Spend ${item.price} shells on “${item.name}” and send it with your next message. You can cancel for a refund before sending.',
              zhTW: '花費 ${item.price} 貝殼買「${item.name}」，隨下一條消息送出。發送前可取消退回。',
            ),
            style: TextStyle(color: YanciTheme.textSecondary, fontSize: 14),
          ),
          confirmLabel: L.pick(en: 'Reserve gift', zhTW: '買下掛起'),
          onConfirm: () => Navigator.of(ctx).pop(true),
          onCancel: () => Navigator.of(ctx).pop(false),
        ),
      );
      if (confirm != true) return;
      final scopeId = widget.pendingScopeId;
      final targetCharId = widget.targetCharId;
      if (scopeId == null || targetCharId == null) return;
      final reservation = await ShopService.reserveShopGift(
        scopeId: scopeId,
        targetCharacterId: targetCharId,
        item: item,
      );
      if (!mounted) return;
      if (reservation != null) {
        widget.onGiftPending?.call(reservation);
        Navigator.of(context).pop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              L.pick(
                en: 'Not enough shells, or another gift is already pending',
                zhTW: '貝殼不足，或已有一件待送禮物',
              ),
            ),
          ),
        );
      }
      return;
    }

    final isGift = widget.mode == ShopMode.giftToChar;
    final title = isGift
        ? L.pick(en: 'Confirm gift', zhTW: '贈送確認')
        : L.pick(en: 'Confirm purchase', zhTW: '購買確認');
    final content = isGift
        ? L.pick(
            en: 'Spend ${item.price} shells on “${item.name}” and gift it?',
            zhTW: '確定要花費 ${item.price} 貝殼購買「${item.name}」並送給TA嗎？',
          )
        : L.pick(
            en: 'Spend ${item.price} shells on “${item.name}”?',
            zhTW: '確定要花費 ${item.price} 貝殼購買「${item.name}」嗎？',
          );
    final confirmLabel = isGift
        ? L.pick(en: 'Buy and gift', zhTW: '購買並贈送')
        : L.pick(en: 'Buy', zhTW: '購買');

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ThemedDialog(
        title: title,
        content: Text(
          content,
          style: TextStyle(color: YanciTheme.textSecondary, fontSize: 14),
        ),
        confirmLabel: confirmLabel,
        onConfirm: () => Navigator.of(ctx).pop(true),
        onCancel: () => Navigator.of(ctx).pop(false),
      ),
    );
    if (confirm == true) {
      final targetId = isGift && widget.targetCharId != null
          ? widget.targetCharId!
          : 'user';
      // 送禮標歸屬：對方背包裡顯示「XX-暱稱送的」
      final giverName = targetId == 'user'
          ? ''
          : await UserSettings.getUserName();
      final res = await ShopService.buyItemAsUser(
        item.id,
        targetOwnerId: targetId,
        givenBy: giverName,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res['message']),
            backgroundColor: res['success'] == true
                ? Colors.green.withValues(alpha: 0.85)
                : Colors.red.withValues(alpha: 0.85),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          ),
        );
      }
    }
  }

  Future<void> _handleDelete(ShopItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ThemedDialog(
        title: L.pick(en: 'Confirm deletion', zhTW: '刪除確認'),
        content: Text(
          L.pick(
            en: 'Delete “${item.name}” from the shop? This cannot be undone.',
            zhTW: '確定要從商店中刪除「${item.name}」嗎？此操作無法還原。',
          ),
          style: TextStyle(color: YanciTheme.textSecondary, fontSize: 14),
        ),
        confirmLabel: L.pick(en: 'Delete', zhTW: '刪除'),
        confirmColor: Colors.redAccent,
        onConfirm: () => Navigator.of(ctx).pop(true),
        onCancel: () => Navigator.of(ctx).pop(false),
      ),
    );
    if (confirm == true) {
      await ShopService.deleteShopItem(item.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L.pick(en: 'Item deleted', zhTW: '已刪除商品')),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          ),
        );
        _loadItems();
      }
    }
  }
}

// ════════════════════════════════════════════════════════════════════
// 背包 Bottom Sheet
// ════════════════════════════════════════════════════════════════════

class BackpackBottomSheet extends StatefulWidget {
  final String ownerId;
  final String? pendingScopeId;
  final String? targetCharId;

  /// 聊天內打開時傳入：durable reservation 建立後回傳聊天頁。
  final void Function(PendingGiftReservation reservation)? onGiftOut;

  const BackpackBottomSheet({
    super.key,
    required this.ownerId,
    this.pendingScopeId,
    this.targetCharId,
    this.onGiftOut,
  });

  @override
  State<BackpackBottomSheet> createState() => _BackpackBottomSheetState();
}

class _BackpackBottomSheetState extends State<BackpackBottomSheet>
    with SingleTickerProviderStateMixin {
  List<BackpackItem> _items = [];
  bool _isLoading = true;
  late AnimationController _staggerController;

  /// 結婚證（已簽署後常駐 user 背包頂部）
  MarriageCertDisplay? _marriageCert;

  @override
  void initState() {
    super.initState();
    _staggerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _loadItems();
  }

  @override
  void dispose() {
    _staggerController.dispose();
    super.dispose();
  }

  Future<void> _loadItems() async {
    final items = await ShopService.getBackpackItems(widget.ownerId);
    // 結婚證：user 背包 + 已簽署 → 頂部展示
    MarriageCertDisplay? cert;
    final charId = widget.targetCharId;
    if (widget.ownerId == 'user' &&
        charId != null &&
        await MarriageService.isMarried(charId)) {
      final char = await DatabaseHelper.getCharacter(charId);
      final nick = await UserSettings.getUserName();
      cert = MarriageCertDisplay(
        userName: nick.isNotEmpty ? nick : '對方',
        charName: char?['name'] as String? ?? '',
        signed: true,
        date: await MarriageService.marriageDate(charId),
      );
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _marriageCert = cert;
      _isLoading = false;
    });
    _staggerController.forward(from: 0);
  }

  /// user 背包物品操作：八折回收 / 送出（聊天內才有）
  Future<void> _showItemActions(BackpackItem item) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          item.displayName,
          style: TextStyle(
            fontSize: 15,
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        children: [
          if (widget.onGiftOut != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'gift'),
              child: Row(
                children: [
                  Icon(
                    Icons.card_giftcard_rounded,
                    size: 18,
                    color: YanciTheme.accent,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    L.pick(en: 'Gift with next message', zhTW: '送給TA（隨下一條消息）'),
                    style: TextStyle(color: YanciTheme.textPrimary),
                  ),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'sell'),
            child: Row(
              children: [
                Icon(
                  Icons.currency_exchange_rounded,
                  size: 18,
                  color: YanciTheme.textSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  L.pick(en: 'Sell back for 80%', zhTW: '八折回收'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (action == 'sell') {
      final refund = await ShopService.sellUserItem(item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            refund != null
                ? L.pick(
                    en: 'Sold back for $refund shells',
                    zhTW: '已回收，返還 $refund 貝殼',
                  )
                : L.pick(en: 'Sell-back failed', zhTW: '回收失敗'),
          ),
        ),
      );
      _loadItems();
    } else if (action == 'gift' && widget.onGiftOut != null) {
      final scopeId = widget.pendingScopeId;
      final targetCharId = widget.targetCharId;
      final rowId = item.id;
      if (scopeId == null || targetCharId == null || rowId == null) return;
      final reservation = await ShopService.reserveBackpackGift(
        scopeId: scopeId,
        targetCharacterId: targetCharId,
        rowId: rowId,
      );
      if (reservation != null) {
        widget.onGiftOut!(reservation);
        if (mounted) Navigator.of(context).pop(); // 關背包回聊天
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              L.pick(
                en: 'The item changed, or another gift is already pending',
                zhTW: '物品已變動，或已有一件待送禮物',
              ),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = _items.fold<int>(0, (sum, i) => sum + i.quantity);

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: YanciTheme.surfacePanel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: YanciTheme.accent.withValues(alpha: 0.08),
            blurRadius: 30,
            spreadRadius: -5,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Drag handle ──
          _buildDragHandle(),
          // ── Gradient accent line ──
          Container(
            height: 1.5,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  YanciTheme.accent.withValues(alpha: 0.5),
                  YanciTheme.accentLight.withValues(alpha: 0.3),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          // ── Header ──
          ClipRRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
                color: YanciTheme.glassInputBg.withValues(alpha: 0.3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.backpack_rounded,
                          color: YanciTheme.accent,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          L.pick(
                            en: widget.ownerId == 'user'
                                ? 'My Backpack'
                                : 'Character Backpack',
                            zhTW: widget.ownerId == 'user' ? '我的背包' : '角色背包',
                          ),
                          style: YanciTheme.headingMedium.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    // ── Item count badge ──
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            YanciTheme.accent.withValues(alpha: 0.15),
                            YanciTheme.accentLight.withValues(alpha: 0.08),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: YanciTheme.accent.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.inventory_2_rounded,
                            size: 13,
                            color: YanciTheme.accent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            L.pick(
                              en: '$totalCount items',
                              zhTW: '$totalCount 件',
                            ),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.accent,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ── 結婚證（簽署後常駐背包頂部）──
          if (!_isLoading && _marriageCert != null)
            Center(
              child: MarriageCertCard(
                userName: _marriageCert!.userName,
                charName: _marriageCert!.charName,
                signed: true,
                date: _marriageCert!.date,
                expanded: true,
              ),
            ),
          // ── Content ──
          Expanded(
            child: _isLoading
                ? Center(
                    child: CircularProgressIndicator(color: YanciTheme.accent),
                  )
                : _items.isEmpty && _marriageCert == null
                ? _EmptyState(
                    icon: Icons.backpack_rounded,
                    text: L.pick(
                      en: 'The backpack is empty.\nTake a look in the shop!',
                      zhTW: '背包空空如也\n快去商店看看吧！',
                    ),
                  )
                : AnimatedBuilder(
                    animation: _staggerController,
                    builder: (_, _) => GridView.builder(
                      padding: const EdgeInsets.all(20),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            childAspectRatio: 0.72,
                            crossAxisSpacing: 14,
                            mainAxisSpacing: 18,
                          ),
                      itemCount: _items.length,
                      itemBuilder: (ctx, i) {
                        final delay = (i / _items.length).clamp(0.0, 1.0);
                        final t = Curves.easeOut.transform(
                          ((_staggerController.value - delay * 0.5) /
                                  (1.0 - delay * 0.5))
                              .clamp(0.0, 1.0),
                        );
                        return Opacity(
                          opacity: t,
                          child: Transform.scale(
                            scale: 0.85 + 0.15 * t,
                            child: GestureDetector(
                              onTap: widget.ownerId == 'user'
                                  ? () => _showItemActions(_items[i])
                                  : null,
                              child: _BackpackItemCard(item: _items[i]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Shared Widgets
// ════════════════════════════════════════════════════════════════════

Widget _buildDragHandle() {
  return Center(
    child: Container(
      margin: const EdgeInsets.only(top: 10, bottom: 6),
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            YanciTheme.accent.withValues(alpha: 0.4),
            YanciTheme.accentLight.withValues(alpha: 0.2),
          ],
        ),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// 商店商品卡片
class _ShopItemCard extends StatefulWidget {
  final ShopItem item;
  final VoidCallback onBuy;
  final VoidCallback onDelete;
  const _ShopItemCard({
    required this.item,
    required this.onBuy,
    required this.onDelete,
  });

  @override
  State<_ShopItemCard> createState() => _ShopItemCardState();
}

class _ShopItemCardState extends State<_ShopItemCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onBuy();
      },
      onTapCancel: () => setState(() => _pressed = false),
      onLongPress: widget.onDelete,
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                YanciTheme.glassInputBg.withValues(alpha: 0.9),
                YanciTheme.glassInputBg.withValues(alpha: 0.4),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: YanciTheme.accent.withValues(alpha: 0.12),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: YanciTheme.accent.withValues(alpha: 0.04),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                // Subtle top-left highlight
                Positioned(
                  top: -8,
                  left: -8,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          YanciTheme.accent.withValues(alpha: 0.06),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      // ── Image area ──
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: Colors.transparent,
                          ),
                          padding: const EdgeInsets.all(8),
                          child: Center(
                            child: item.imagePath.isNotEmpty
                                ? Image.file(
                                    File(item.imagePath),
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.none,
                                  )
                                : Icon(
                                    Icons.inventory_2_outlined,
                                    size: 36,
                                    color: YanciTheme.textSecondary.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // ── Name ──
                      Text(
                        item.name,
                        style: YanciTheme.bodySmall.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      // ── Price ──
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.asset(
                              'assets/images/shell_coin.png',
                              width: 13,
                              height: 13,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${item.price}',
                              style: TextStyle(
                                color: YanciTheme.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                fontFamily: 'Courier',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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

/// 背包物品卡片
class _BackpackItemCard extends StatelessWidget {
  final BackpackItem item;
  const _BackpackItemCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  YanciTheme.accent.withValues(alpha: 0.06),
                  YanciTheme.glassInputBg.withValues(alpha: 0.7),
                  YanciTheme.surfacePanel,
                ],
                radius: 0.9,
                stops: const [0.0, 0.5, 1.0],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: YanciTheme.accent.withValues(alpha: 0.15),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: YanciTheme.accent.withValues(alpha: 0.04),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Item image
                if (item.imagePath != null && item.imagePath!.isNotEmpty)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Image.file(
                        File(item.imagePath!),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.none,
                      ),
                    ),
                  )
                else
                  Icon(
                    Icons.category_outlined,
                    size: 28,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                  ),
                // Quantity badge
                if (item.quantity > 1)
                  Positioned(
                    right: -5,
                    top: -5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [YanciTheme.accent, YanciTheme.accentLight],
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: YanciTheme.surfacePanel,
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Text(
                        '${item.quantity}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'Courier',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          // 「杯子-昭昭送的」；自己買的無後綴
          item.displayName.isEmpty
              ? L.pick(en: 'Unknown item', zhTW: '未知物品')
              : item.displayName,
          style: YanciTheme.bodySmall.copyWith(
            fontWeight: FontWeight.w600,
            color: YanciTheme.textPrimary,
            fontSize: 11,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Header 按鈕
class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: YanciTheme.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: YanciTheme.accent.withValues(alpha: 0.12),
            ),
          ),
          child: Icon(icon, color: YanciTheme.accent, size: 20),
        ),
      ),
    );
  }
}

/// 空狀態
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyState({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  YanciTheme.accent.withValues(alpha: 0.08),
                  Colors.transparent,
                ],
                radius: 0.6,
              ),
            ),
            child: Icon(
              icon,
              size: 36,
              color: YanciTheme.textSecondary.withValues(alpha: 0.25),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: YanciTheme.bodyText.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.45),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 主題化對話框（統一商店/背包的彈窗風格）
class _ThemedDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final String confirmLabel;
  final Color? confirmColor;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _ThemedDialog({
    required this.title,
    required this.content,
    required this.confirmLabel,
    this.confirmColor,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: YanciTheme.surfacePanel.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: YanciTheme.accent.withValues(alpha: 0.15),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: YanciTheme.headingMedium.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                content,
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: onCancel,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: YanciTheme.glassBorder),
                          ),
                        ),
                        child: Text(
                          L.pick(en: 'Cancel', zhTW: '取消'),
                          style: TextStyle(color: YanciTheme.textSecondary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextButton(
                        onPressed: onConfirm,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          backgroundColor: (confirmColor ?? YanciTheme.accent)
                              .withValues(alpha: 0.15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          confirmLabel,
                          style: TextStyle(
                            color: confirmColor ?? YanciTheme.accent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 主題化輸入框
class _ThemedTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputType? keyboardType;
  const _ThemedTextField({
    required this.controller,
    required this.hint,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: YanciTheme.bodyText.copyWith(fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: YanciTheme.bodySmall.copyWith(
          color: YanciTheme.textSecondary.withValues(alpha: 0.4),
        ),
        filled: true,
        fillColor: YanciTheme.glassInputBg.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: YanciTheme.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: YanciTheme.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: YanciTheme.accent.withValues(alpha: 0.5),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}
