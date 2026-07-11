import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../memory/database.dart';
import 'package:uuid/uuid.dart';
import 'locale_strings.dart';
import 'scratch_service.dart';

class ShopItem {
  final String id;
  final String name;
  final String description;
  final int price;
  final String type; // 'consumable', 'non_consumable'
  final String category;
  final int sortOrder;
  final String imagePath;

  ShopItem({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    required this.type,
    required this.category,
    required this.sortOrder,
    required this.imagePath,
  });

  factory ShopItem.fromMap(Map<String, dynamic> map) {
    return ShopItem(
      id: map['id'] as String,
      name: map['name'] as String,
      description: map['description'] as String? ?? '',
      price: map['price'] as int,
      type: map['type'] as String,
      category: map['category'] as String? ?? '',
      sortOrder: map['sort_order'] as int? ?? 0,
      imagePath: map['image_path'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'price': price,
      'type': type,
      'category': category,
      'sort_order': sortOrder,
      'image_path': imagePath,
    };
  }
}

class BackpackItem {
  final int? id;
  final String ownerId;
  final String itemId;
  final int quantity;
  final String givenBy; // ''=自己買的，否則為贈送者名
  final bool starred; // 模型標記的重要物品
  final String createdAt;
  final String updatedAt;

  // Joined properties for UI convenience
  final String? name;
  final String? type;
  final String? imagePath;
  final String? description;

  BackpackItem({
    this.id,
    required this.ownerId,
    required this.itemId,
    required this.quantity,
    this.givenBy = '',
    this.starred = false,
    required this.createdAt,
    required this.updatedAt,
    this.name,
    this.type,
    this.imagePath,
    this.description,
  });

  /// 顯示名：「杯子-昭昭送的」；自己買的無後綴
  String get displayName =>
      givenBy.isEmpty ? (name ?? '') : '${name ?? ''}-$givenBy送的';

  factory BackpackItem.fromMap(Map<String, dynamic> map) {
    return BackpackItem(
      id: map['id'] as int?,
      ownerId: map['owner_id'] as String,
      itemId: map['item_id'] as String,
      quantity: map['quantity'] as int,
      givenBy: map['given_by'] as String? ?? '',
      starred: (map['starred'] as int? ?? 0) == 1,
      createdAt: map['created_at'] as String,
      updatedAt: map['updated_at'] as String,
      name: map['name'] as String?,
      type: map['type'] as String?,
      imagePath: map['image_path'] as String?,
      description: map['description'] as String?,
    );
  }
}

/// Durable, conversation-scoped gift reservation. It intentionally lives in
/// SharedPreferences so existing database/backup schemas remain unchanged.
class PendingGiftReservation {
  static const String shopSource = 'shop';
  static const String backpackSource = 'backpack';

  final String id;
  final String scopeId;
  final String targetCharacterId;
  final String sourceType;
  final String itemId;
  final String itemName;
  final int price;
  final String sourceOwnerId;
  final String sourceGivenBy;
  final String state;
  final String walletOperationId;
  final String resolutionOperationId;
  final String mutationOwnerId;
  final String mutationGivenBy;
  final int? mutationBeforeQuantity;
  final int mutationDelta;
  final String createdAt;

  const PendingGiftReservation({
    required this.id,
    required this.scopeId,
    required this.targetCharacterId,
    required this.sourceType,
    required this.itemId,
    required this.itemName,
    required this.price,
    required this.sourceOwnerId,
    required this.sourceGivenBy,
    required this.state,
    required this.walletOperationId,
    required this.resolutionOperationId,
    required this.mutationOwnerId,
    required this.mutationGivenBy,
    required this.mutationBeforeQuantity,
    required this.mutationDelta,
    required this.createdAt,
  });

  PendingGiftReservation copyWith({
    String? state,
    String? resolutionOperationId,
    String? mutationOwnerId,
    String? mutationGivenBy,
    int? mutationBeforeQuantity,
    bool clearMutationBeforeQuantity = false,
    int? mutationDelta,
  }) => PendingGiftReservation(
    id: id,
    scopeId: scopeId,
    targetCharacterId: targetCharacterId,
    sourceType: sourceType,
    itemId: itemId,
    itemName: itemName,
    price: price,
    sourceOwnerId: sourceOwnerId,
    sourceGivenBy: sourceGivenBy,
    state: state ?? this.state,
    walletOperationId: walletOperationId,
    resolutionOperationId: resolutionOperationId ?? this.resolutionOperationId,
    mutationOwnerId: mutationOwnerId ?? this.mutationOwnerId,
    mutationGivenBy: mutationGivenBy ?? this.mutationGivenBy,
    mutationBeforeQuantity: clearMutationBeforeQuantity
        ? null
        : mutationBeforeQuantity ?? this.mutationBeforeQuantity,
    mutationDelta: mutationDelta ?? this.mutationDelta,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'scope_id': scopeId,
    'target_character_id': targetCharacterId,
    'source_type': sourceType,
    'item_id': itemId,
    'item_name': itemName,
    'price': price,
    'source_owner_id': sourceOwnerId,
    'source_given_by': sourceGivenBy,
    'state': state,
    'wallet_operation_id': walletOperationId,
    'resolution_operation_id': resolutionOperationId,
    'mutation_owner_id': mutationOwnerId,
    'mutation_given_by': mutationGivenBy,
    'mutation_before_quantity': mutationBeforeQuantity,
    'mutation_delta': mutationDelta,
    'created_at': createdAt,
  };

  factory PendingGiftReservation.fromJson(Map<String, dynamic> json) =>
      PendingGiftReservation(
        id: json['id'] as String,
        scopeId: json['scope_id'] as String,
        targetCharacterId: json['target_character_id'] as String,
        sourceType: json['source_type'] as String,
        itemId: json['item_id'] as String,
        itemName: json['item_name'] as String? ?? '禮物',
        price: json['price'] as int? ?? 0,
        sourceOwnerId: json['source_owner_id'] as String? ?? 'user',
        sourceGivenBy: json['source_given_by'] as String? ?? '',
        state: json['state'] as String? ?? 'reserved',
        walletOperationId: json['wallet_operation_id'] as String? ?? '',
        resolutionOperationId: json['resolution_operation_id'] as String? ?? '',
        mutationOwnerId: json['mutation_owner_id'] as String? ?? '',
        mutationGivenBy: json['mutation_given_by'] as String? ?? '',
        mutationBeforeQuantity: json['mutation_before_quantity'] as int?,
        mutationDelta: json['mutation_delta'] as int? ?? 0,
        createdAt:
            json['created_at'] as String? ?? DateTime.now().toIso8601String(),
      );
}

class ShopService {
  static const String _pendingGiftPrefix = 'pending_gift_v1:';
  static Future<void> _giftSerialTail = Future<void>.value();

  static Future<T> _giftSerialized<T>(Future<T> Function() action) async {
    final previous = _giftSerialTail;
    final release = Completer<void>();
    _giftSerialTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  static String _pendingGiftKey(String scopeId) =>
      '$_pendingGiftPrefix$scopeId';

  // ═══ 商店功能開關（默認開；關=不注入工具說明，標籤照樣不觸發）═══
  static const String _kEnabled = 'shop_enabled';

  static Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kEnabled) ?? true;
  }

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
  }

  // ═══ 背包注入（開窗首條，跟隨歷史進緩存前綴）═══
  /// 水位：上次全量注入時背包最大行 id；無新增則只注 starred
  static String _seenKey(String charId) => 'pack_seen_maxid_$charId';

  /// 查角色背包行（帶商品名）。onlyStarred=true 只取星標。
  static Future<List<BackpackItem>> _packRows(
    String ownerId, {
    bool onlyStarred = false,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT b.*, s.name FROM backpack_items b
      INNER JOIN shop_items s ON b.item_id = s.id
      WHERE b.owner_id = ?${onlyStarred ? ' AND b.starred = 1' : ''}
      ORDER BY b.id ASC
    ''',
      [ownerId],
    );
    return rows.map(BackpackItem.fromMap).toList();
  }

  /// 開窗首條的背包注入文本。有新增 → 全量 + 請模型 `<pack_star>` 重標；
  /// 無新增 → 只注星標（空則返回 ''，零開銷）。
  static Future<String> buildPackPrompt(String charId) async {
    final all = await _packRows(charId);
    if (all.isEmpty) return '';
    final p = await SharedPreferences.getInstance();
    final seen = p.getInt(_seenKey(charId)) ?? 0;
    final maxId = all.last.id ?? 0;

    String line(BackpackItem b) =>
        '[#${b.id}] ${b.displayName} ×${b.quantity}${b.starred ? ' ★' : ''}';

    if (maxId > seen) {
      await p.setInt(_seenKey(charId), maxId);
      final header = L.pick(en: '【Your Backpack】', zhTW: '【你的背包】');
      final instruction = L.pick(
        en: 'At the end of this reply, use <pack_star>id,id</pack_star> to mark the 3–5 items most important to you. This replaces old marks; later windows will include only these.',
        zhTW:
            '請在本次回覆末尾用 <pack_star>編號,編號</pack_star> 標出對你最重要的 3~5 件（覆蓋舊標記，之後的窗口只會帶上這些）。',
      );
      return '$header\n${all.map(line).join('\n')}\n$instruction';
    }
    final starredRows = all.where((b) => b.starred).toList();
    if (starredRows.isEmpty) return '';
    final header = L.pick(
      en: '【Your Backpack (items you marked important)】',
      zhTW: '【你的背包（你標記過的重要物品）】',
    );
    return '$header\n${starredRows.map(line).join('\n')}';
  }

  /// `<pack_star>` 覆蓋式落庫
  static Future<void> applyPackStar(String charId, List<int> ids) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      await txn.update(
        'backpack_items',
        {'starred': 0},
        where: 'owner_id = ?',
        whereArgs: [charId],
      );
      if (ids.isEmpty) return;
      final ph = List.filled(ids.length, '?').join(',');
      await txn.rawUpdate(
        'UPDATE backpack_items SET starred = 1 '
        'WHERE owner_id = ? AND id IN ($ph)',
        [charId, ...ids],
      );
    });
  }

  /// 窗內背包快照（行id→數量）與 delta 文本，供 chat_screen 動態注入
  static Future<Map<int, int>> packQtySnapshot(String ownerId) async {
    final rows = await _packRows(ownerId);
    return {for (final b in rows) b.id ?? 0: b.quantity};
  }

  static Future<String> buildPackDelta(
    String ownerId,
    Map<int, int> snapshot,
  ) async {
    final rows = await _packRows(ownerId);
    final parts = <String>[];
    for (final b in rows) {
      final old = snapshot[b.id] ?? 0;
      final diff = b.quantity - old;
      if (diff != 0) {
        final tag = b.givenBy.isEmpty
            ? ''
            : '${L.pick(en: ' (gift from ', zhTW: '（')}${b.givenBy}${L.pick(en: ')', zhTW: '送的）')}';
        parts.add('${b.name}${diff > 0 ? '+' : ''}$diff$tag');
      }
    }
    return parts.join(L.pick(en: ', ', zhTW: '，'));
  }

  /// 副檔名白名單化：只取最後一段、限純英數 1~5 字。
  /// 防止選檔器返回的奇異檔名（含 `/`、無點、超長段）拼進
  /// 寫入路徑造成越目錄寫檔或垃圾檔名。不合規一律落 png。
  static String _safeImageExtension(String sourcePath) {
    final dotIdx = sourcePath.lastIndexOf('.');
    if (dotIdx < 0 || dotIdx == sourcePath.length - 1) return 'png';
    final ext = sourcePath.substring(dotIdx + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'png';
  }

  /// 獲取所有商品（依分類、排序排列）
  static Future<List<ShopItem>> getShopItems() async {
    final db = await DatabaseHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'shop_items',
      orderBy: 'sort_order ASC, name ASC',
    );
    return maps.map((e) => ShopItem.fromMap(e)).toList();
  }

  static Future<String> buildShopListPromptText() async {
    final shopItems = await getShopItems();
    if (shopItems.isEmpty) {
      return L.pick(en: 'The shop currently has no items.', zhTW: '目前商店無商品');
    }
    return shopItems
        .map(
          (e) =>
              '- [id:${e.id}] ${e.name} (${e.price}${L.pick(en: ' shells', zhTW: '貝殼')}) [${e.type}]',
        )
        .join('\n  ');
  }

  /// 按名稱查商品圖片（禮物卡片顯示用；[gift:名] 標記只有名字沒有 id）
  static Future<String?> findItemImagePathByName(String name) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'shop_items',
      columns: ['image_path'],
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['image_path'] as String?;
  }

  /// 獲取指定 owner 的背包物品（聯表查詢出商品詳細資訊）
  static Future<List<BackpackItem>> getBackpackItems(String ownerId) async {
    final db = await DatabaseHelper.database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT b.*, s.name, s.type, s.image_path, s.description
      FROM backpack_items b
      INNER JOIN shop_items s ON b.item_id = s.id
      WHERE b.owner_id = ?
      ORDER BY b.updated_at DESC
    ''',
      [ownerId],
    );
    return maps.map((e) => BackpackItem.fromMap(e)).toList();
  }

  /// 新增商品到商店（包含圖片處理）
  static Future<void> addShopItem({
    required String name,
    required String description,
    required int price,
    required String type,
    required String category,
    required int sortOrder,
    required String imageSourcePath,
  }) async {
    final db = await DatabaseHelper.database;
    final id = const Uuid().v4();

    // 儲存圖片到應用程式專屬目錄
    String savedImagePath = '';
    if (imageSourcePath.isNotEmpty) {
      final sourceFile = File(imageSourcePath);
      if (sourceFile.existsSync()) {
        final docDir = await getApplicationDocumentsDirectory();
        final shopDir = Directory('${docDir.path}/shop_items');
        if (!shopDir.existsSync()) {
          shopDir.createSync(recursive: true);
        }

        final extension = _safeImageExtension(imageSourcePath);
        final targetPath = '${shopDir.path}/$id.$extension';
        await sourceFile.copy(targetPath);
        savedImagePath = targetPath;
      }
    }

    final item = ShopItem(
      id: id,
      name: name,
      description: description,
      price: price,
      type: type,
      category: category,
      sortOrder: sortOrder,
      imagePath: savedImagePath,
    );

    await db.insert('shop_items', item.toMap());
  }

  /// 更新商品（包含圖片處理）
  static Future<void> updateShopItem({
    required String id,
    required String name,
    required String description,
    required int price,
    required String type,
    required String category,
    required int sortOrder,
    String? imageSourcePath, // 如果有新圖才傳
  }) async {
    final db = await DatabaseHelper.database;

    final existing = await db.query(
      'shop_items',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (existing.isEmpty) return;

    String savedImagePath = existing.first['image_path'] as String? ?? '';

    if (imageSourcePath != null && imageSourcePath.isNotEmpty) {
      final sourceFile = File(imageSourcePath);
      if (sourceFile.existsSync()) {
        final docDir = await getApplicationDocumentsDirectory();
        final shopDir = Directory('${docDir.path}/shop_items');
        if (!shopDir.existsSync()) {
          shopDir.createSync(recursive: true);
        }

        // 刪除舊圖
        if (savedImagePath.isNotEmpty) {
          final oldFile = File(savedImagePath);
          if (oldFile.existsSync()) {
            oldFile.deleteSync();
          }
        }

        final extension = _safeImageExtension(imageSourcePath);
        final targetPath = '${shopDir.path}/$id.$extension';
        await sourceFile.copy(targetPath);
        savedImagePath = targetPath;
      }
    }

    final item = ShopItem(
      id: id,
      name: name,
      description: description,
      price: price,
      type: type,
      category: category,
      sortOrder: sortOrder,
      imagePath: savedImagePath,
    );

    await db.update(
      'shop_items',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 刪除商品
  static Future<void> deleteShopItem(String id) async {
    final db = await DatabaseHelper.database;
    final existing = await db.query(
      'shop_items',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (existing.isNotEmpty) {
      final path = existing.first['image_path'] as String? ?? '';
      if (path.isNotEmpty) {
        final file = File(path);
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
    }

    await db.delete('shop_items', where: 'id = ?', whereArgs: [id]);
    await db.delete('backpack_items', where: 'item_id = ?', whereArgs: [id]);
  }

  // ═══ Durable pending gifts ═══

  static PendingGiftReservation? _readPendingGift(
    SharedPreferences prefs,
    String scopeId,
  ) {
    final raw = prefs.getString(_pendingGiftKey(scopeId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return PendingGiftReservation.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
    return null;
  }

  static Future<void> _writePendingGift(
    SharedPreferences prefs,
    PendingGiftReservation reservation,
  ) async {
    await prefs.setString(
      _pendingGiftKey(reservation.scopeId),
      jsonEncode(reservation.toJson()),
    );
  }

  static Future<void> _removePendingGift(
    SharedPreferences prefs,
    String scopeId,
  ) async {
    await prefs.remove(_pendingGiftKey(scopeId));
  }

  static Future<int> _backpackQuantity(
    String ownerId,
    String itemId,
    String givenBy,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'backpack_items',
      columns: ['quantity'],
      where: 'owner_id = ? AND item_id = ? AND given_by = ?',
      whereArgs: [ownerId, itemId, givenBy],
      limit: 1,
    );
    return rows.isEmpty ? 0 : rows.first['quantity'] as int? ?? 0;
  }

  /// Applies a recorded absolute quantity transition. Repeating it after a
  /// crash is a no-op when the target quantity is already present.
  static Future<void> _applyBackpackMutation(
    PendingGiftReservation reservation,
  ) async {
    final before = reservation.mutationBeforeQuantity;
    if (before == null || reservation.mutationOwnerId.isEmpty) {
      throw StateError('Pending gift has no backpack mutation checkpoint');
    }
    final target = before + reservation.mutationDelta;
    if (target < 0) {
      throw StateError('Pending gift would create negative stock');
    }

    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'backpack_items',
        columns: ['id', 'quantity'],
        where: 'owner_id = ? AND item_id = ? AND given_by = ?',
        whereArgs: [
          reservation.mutationOwnerId,
          reservation.itemId,
          reservation.mutationGivenBy,
        ],
        limit: 1,
      );
      final current = rows.isEmpty ? 0 : rows.first['quantity'] as int? ?? 0;
      if (current == target) return;
      if (current != before) {
        throw StateError(
          'Backpack changed while pending gift was being committed '
          '(expected $before or $target, got $current)',
        );
      }

      final now = DateTime.now().toIso8601String();
      if (target == 0) {
        if (rows.isNotEmpty) {
          await txn.delete(
            'backpack_items',
            where: 'id = ?',
            whereArgs: [rows.first['id']],
          );
        }
      } else if (rows.isNotEmpty) {
        await txn.update(
          'backpack_items',
          {'quantity': target, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [rows.first['id']],
        );
      } else {
        await txn.insert('backpack_items', {
          'owner_id': reservation.mutationOwnerId,
          'item_id': reservation.itemId,
          'quantity': target,
          'given_by': reservation.mutationGivenBy,
          'created_at': now,
          'updated_at': now,
        });
      }
    });
  }

  static Future<PendingGiftReservation?> _recoverPendingGiftLocked(
    SharedPreferences prefs,
    PendingGiftReservation reservation,
  ) async {
    var current = reservation;
    if (current.state == 'preparing_shop') {
      final result = await ScratchService.applyWalletOperation(
        operationId: current.walletOperationId,
        deltas: {ScratchService.userAccountId: -current.price},
      );
      if (result == WalletOperationResult.insufficientFunds) {
        await _removePendingGift(prefs, current.scopeId);
        return null;
      }
      current = current.copyWith(state: 'reserved');
      await _writePendingGift(prefs, current);
    } else if (current.state == 'preparing_backpack') {
      await _applyBackpackMutation(current);
      current = current.copyWith(
        state: 'reserved',
        mutationOwnerId: '',
        mutationGivenBy: '',
        clearMutationBeforeQuantity: true,
        mutationDelta: 0,
      );
      await _writePendingGift(prefs, current);
    } else if (current.state == 'canceling_shop') {
      await ScratchService.applyWalletOperation(
        operationId: current.resolutionOperationId,
        deltas: {ScratchService.userAccountId: current.price},
      );
      await _removePendingGift(prefs, current.scopeId);
      await ScratchService.completeWalletOperation(current.walletOperationId);
      await ScratchService.completeWalletOperation(
        current.resolutionOperationId,
      );
      return null;
    } else if (current.state == 'canceling_backpack') {
      await _applyBackpackMutation(current);
      await _removePendingGift(prefs, current.scopeId);
      return null;
    } else if (current.state == 'delivering') {
      await _applyBackpackMutation(current);
      await _removePendingGift(prefs, current.scopeId);
      if (current.walletOperationId.isNotEmpty) {
        await ScratchService.completeWalletOperation(current.walletOperationId);
      }
      return null;
    }
    return current;
  }

  static Future<PendingGiftReservation?> getPendingGift({
    required String scopeId,
    required String targetCharacterId,
  }) {
    return _giftSerialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final reservation = _readPendingGift(prefs, scopeId);
      if (reservation == null) return null;
      final recovered = await _recoverPendingGiftLocked(prefs, reservation);
      if (recovered?.targetCharacterId != targetCharacterId) return null;
      return recovered;
    });
  }

  static Future<PendingGiftReservation?> reserveShopGift({
    required String scopeId,
    required String targetCharacterId,
    required ShopItem item,
  }) {
    return _giftSerialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final existing = _readPendingGift(prefs, scopeId);
      if (existing != null) {
        final recovered = await _recoverPendingGiftLocked(prefs, existing);
        if (recovered != null) return null;
      }

      final id = const Uuid().v4();
      var reservation = PendingGiftReservation(
        id: id,
        scopeId: scopeId,
        targetCharacterId: targetCharacterId,
        sourceType: PendingGiftReservation.shopSource,
        itemId: item.id,
        itemName: item.name,
        price: item.price,
        sourceOwnerId: 'user',
        sourceGivenBy: '',
        state: 'preparing_shop',
        walletOperationId: 'pending_gift_reserve:$id',
        resolutionOperationId: '',
        mutationOwnerId: '',
        mutationGivenBy: '',
        mutationBeforeQuantity: null,
        mutationDelta: 0,
        createdAt: DateTime.now().toIso8601String(),
      );
      await _writePendingGift(prefs, reservation);
      final result = await ScratchService.applyWalletOperation(
        operationId: reservation.walletOperationId,
        deltas: {ScratchService.userAccountId: -item.price},
      );
      if (result == WalletOperationResult.insufficientFunds) {
        await _removePendingGift(prefs, scopeId);
        return null;
      }
      reservation = reservation.copyWith(state: 'reserved');
      await _writePendingGift(prefs, reservation);
      return reservation;
    });
  }

  static Future<PendingGiftReservation?> reserveBackpackGift({
    required String scopeId,
    required String targetCharacterId,
    required int rowId,
  }) {
    return _giftSerialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final existing = _readPendingGift(prefs, scopeId);
      if (existing != null) {
        final recovered = await _recoverPendingGiftLocked(prefs, existing);
        if (recovered != null) return null;
      }

      final db = await DatabaseHelper.database;
      final rows = await db.rawQuery(
        '''
        SELECT b.*, s.name
        FROM backpack_items b
        INNER JOIN shop_items s ON s.id = b.item_id
        WHERE b.id = ? AND b.owner_id = 'user'
        LIMIT 1
        ''',
        [rowId],
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final quantity = row['quantity'] as int? ?? 0;
      if (quantity <= 0) return null;

      final id = const Uuid().v4();
      var reservation = PendingGiftReservation(
        id: id,
        scopeId: scopeId,
        targetCharacterId: targetCharacterId,
        sourceType: PendingGiftReservation.backpackSource,
        itemId: row['item_id'] as String,
        itemName: row['name'] as String? ?? '禮物',
        price: 0,
        sourceOwnerId: 'user',
        sourceGivenBy: row['given_by'] as String? ?? '',
        state: 'preparing_backpack',
        walletOperationId: '',
        resolutionOperationId: '',
        mutationOwnerId: 'user',
        mutationGivenBy: row['given_by'] as String? ?? '',
        mutationBeforeQuantity: quantity,
        mutationDelta: -1,
        createdAt: DateTime.now().toIso8601String(),
      );
      await _writePendingGift(prefs, reservation);
      await _applyBackpackMutation(reservation);
      reservation = reservation.copyWith(
        state: 'reserved',
        mutationOwnerId: '',
        mutationGivenBy: '',
        clearMutationBeforeQuantity: true,
        mutationDelta: 0,
      );
      await _writePendingGift(prefs, reservation);
      return reservation;
    });
  }

  static Future<bool> cancelPendingGift(String scopeId) {
    return _giftSerialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final stored = _readPendingGift(prefs, scopeId);
      if (stored == null) return false;
      final recovered = await _recoverPendingGiftLocked(prefs, stored);
      if (recovered == null) return true;

      if (recovered.sourceType == PendingGiftReservation.shopSource) {
        final canceling = recovered.copyWith(
          state: 'canceling_shop',
          resolutionOperationId: 'pending_gift_refund:${recovered.id}',
        );
        await _writePendingGift(prefs, canceling);
        await _recoverPendingGiftLocked(prefs, canceling);
      } else {
        final before = await _backpackQuantity(
          recovered.sourceOwnerId,
          recovered.itemId,
          recovered.sourceGivenBy,
        );
        final canceling = recovered.copyWith(
          state: 'canceling_backpack',
          mutationOwnerId: recovered.sourceOwnerId,
          mutationGivenBy: recovered.sourceGivenBy,
          mutationBeforeQuantity: before,
          mutationDelta: 1,
        );
        await _writePendingGift(prefs, canceling);
        await _recoverPendingGiftLocked(prefs, canceling);
      }
      return true;
    });
  }

  static Future<PendingGiftReservation?> deliverPendingGift(
    String scopeId, {
    required String giverName,
  }) {
    return _giftSerialized(() async {
      final prefs = await SharedPreferences.getInstance();
      final stored = _readPendingGift(prefs, scopeId);
      if (stored == null) return null;
      final recovered = await _recoverPendingGiftLocked(prefs, stored);
      if (recovered == null || recovered.state != 'reserved') return null;

      final before = await _backpackQuantity(
        recovered.targetCharacterId,
        recovered.itemId,
        giverName,
      );
      final delivering = recovered.copyWith(
        state: 'delivering',
        mutationOwnerId: recovered.targetCharacterId,
        mutationGivenBy: giverName,
        mutationBeforeQuantity: before,
        mutationDelta: 1,
      );
      await _writePendingGift(prefs, delivering);
      await _recoverPendingGiftLocked(prefs, delivering);
      return recovered;
    });
  }

  static Future<Map<String, dynamic>> buyItemAsUser(
    String itemId, {
    String targetOwnerId = 'user',
    String givenBy = '', // 買給角色時傳用戶暱稱；買給自己留空
  }) async {
    final db = await DatabaseHelper.database;
    final items = await db.query(
      'shop_items',
      where: 'id = ?',
      whereArgs: [itemId],
    );
    if (items.isEmpty) return {'success': false, 'message': '商品不存在'};
    final item = ShopItem.fromMap(items.first);

    final success = await ScratchService.spendUser(item.price);
    if (!success) return {'success': false, 'message': '貝殼餘額不足'};

    try {
      await _grantToBackpack(targetOwnerId, itemId, givenBy);
      return {'success': true, 'message': '購買成功'};
    } catch (e) {
      await ScratchService.earnUser(item.price);
      debugPrint('用戶購買失敗，已退款: $e');
      return {'success': false, 'message': '發生錯誤: $e'};
    }
  }

  /// 送禮掛起流程用：僅扣款不入包（發送時才 grant，取消時 refund）
  static Future<bool> purchasePending(ShopItem item) =>
      ScratchService.spendUser(item.price);

  static Future<void> refundPending(int price) =>
      ScratchService.earnUser(price);

  /// 公開發放入口（掛起送出時：owner=角色id、givenBy=用戶暱稱）
  static Future<void> grantToBackpack(
    String ownerId,
    String itemId,
    String givenBy,
  ) => _grantToBackpack(ownerId, itemId, givenBy);

  /// 從背包移出一件（送出/回收共用）。行不存在返回 false。
  static Future<bool> removeOne(int rowId) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'backpack_items',
        columns: ['quantity'],
        where: 'id = ?',
        whereArgs: [rowId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final qty = rows.first['quantity'] as int? ?? 0;
      if (qty <= 0) return false;
      if (qty == 1) {
        return await txn.delete(
              'backpack_items',
              where: 'id = ? AND quantity = 1',
              whereArgs: [rowId],
            ) ==
            1;
      }
      return await txn.rawUpdate(
            'UPDATE backpack_items '
            'SET quantity = quantity - 1, updated_at = ? '
            'WHERE id = ? AND quantity = ?',
            [DateTime.now().toIso8601String(), rowId, qty],
          ) ==
          1;
    });
  }

  /// 八折回收（僅 user 自己的背包）：移出一件 + 返還 floor(價格×0.8)
  static Future<int?> sellUserItem(BackpackItem b) async {
    if (b.ownerId != 'user' || b.id == null) return null;
    final db = await DatabaseHelper.database;
    final items = await db.query(
      'shop_items',
      where: 'id = ?',
      whereArgs: [b.itemId],
    );
    if (items.isEmpty) return null;
    final price = items.first['price'] as int? ?? 0;
    final refund = (price * 0.8).floor();
    if (!await removeOne(b.id!)) return null;
    await ScratchService.earnUser(refund);
    return refund;
  }

  /// 背包發放（同 owner+item+來源 堆疊，否則新行）
  static Future<void> _grantToBackpack(
    String ownerId,
    String itemId,
    String givenBy,
  ) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'backpack_items',
        where: 'owner_id = ? AND item_id = ? AND given_by = ?',
        whereArgs: [ownerId, itemId, givenBy],
      );
      final nowStr = DateTime.now().toIso8601String();
      if (existing.isNotEmpty) {
        await txn.rawUpdate(
          'UPDATE backpack_items SET quantity = quantity + 1, updated_at = ? WHERE owner_id = ? AND item_id = ? AND given_by = ?',
          [nowStr, ownerId, itemId, givenBy],
        );
      } else {
        await txn.insert('backpack_items', {
          'owner_id': ownerId,
          'item_id': itemId,
          'quantity': 1,
          'given_by': givenBy,
          'created_at': nowStr,
          'updated_at': nowStr,
        });
      }
    });
  }

  /// 購買商品核心邏輯
  /// targetOwnerId: 'user' 或 特定角色ID
  static Future<Map<String, dynamic>> buyItem({
    required String itemId,
    required String targetOwnerId,
    required String sourceCharacterId,
    String givenBy = '', // 送給 user 時傳角色名；買給自己留空
  }) async {
    final db = await DatabaseHelper.database;

    // 1. 檢查商品是否存在
    final items = await db.query(
      'shop_items',
      where: 'id = ?',
      whereArgs: [itemId],
    );
    if (items.isEmpty) {
      return {'success': false, 'message': '商品不存在'};
    }
    final item = ShopItem.fromMap(items.first);

    // 2. 檢查角色與貝殼餘額
    final charRows = await db.query(
      'characters',
      where: 'id = ?',
      whereArgs: [sourceCharacterId],
    );
    if (charRows.isEmpty) {
      return {'success': false, 'message': '角色不存在'};
    }
    final balance = await ScratchService.getCoins(sourceCharacterId);

    if (balance < item.price) {
      return {'success': false, 'message': '貝殼餘額不足'};
    }

    final spent = await ScratchService.spend(sourceCharacterId, item.price);
    if (!spent) {
      return {'success': false, 'message': '貝殼餘額不足'};
    }

    try {
      await _grantToBackpack(targetOwnerId, itemId, givenBy);
      return {'success': true, 'message': '購買成功', 'item': item};
    } catch (e) {
      await ScratchService.earn(sourceCharacterId, item.price);
      debugPrint('購買失敗: $e');
      return {'success': false, 'message': '發生錯誤: $e'};
    }
  }

  static String? _buyAttr(String attrs, String name) {
    final re = RegExp(
      "\\b${RegExp.escape(name)}\\s*=\\s*(['\"])(.*?)\\1",
      caseSensitive: false,
    );
    return re.firstMatch(attrs)?.group(2)?.trim();
  }

  /// 本輪 `<buy>` 處理結果（chat_screen 消費後 clear）：
  /// {success:'1'/'0', name:商品名, target:'user'/'self', reason:失敗原因}
  static final List<Map<String, String>> lastBuyResults = [];

  /// 待注入下一輪動態上下文的購買失敗提示（消費即清）。
  /// 模型以為送出去了但實際失敗 → 劇情與帳本脫節，必須告訴她。
  static String? pendingBuyFailureNote;

  /// 處理模型回覆中的 `<buy>` 標籤
  /// 格式: `<buy item="ID" target="self" />`
  /// 注意：本函數不再自行插入系統訊息——結果進 lastBuyResults，
  /// 由 chat_screen 統一落庫+即時上屏（雙路徑同一消費點）。
  static Future<String> processReply(
    String text, {
    required String characterId,
    String characterName = '', // 送禮歸屬顯示用（given_by）
    String? conversationId,
  }) async {
    var processed = text;
    final db = await DatabaseHelper.database;
    final buyRegex = RegExp(r'<buy\b([^>]*)/?>', caseSensitive: false);
    final matches = buyRegex.allMatches(processed).toList();

    for (final match in matches) {
      final attrs = match.group(1) ?? '';
      final itemId = _buyAttr(attrs, 'item');
      final target = (_buyAttr(attrs, 'target') ?? 'self').toLowerCase();

      if (itemId != null && itemId.isNotEmpty) {
        // 正規化 targetOwnerId
        final targetOwnerId = (target == 'user' || target == '用戶')
            ? 'user'
            : characterId;

        final result = await buyItem(
          itemId: itemId,
          targetOwnerId: targetOwnerId,
          sourceCharacterId: characterId,
          givenBy: targetOwnerId == 'user' ? characterName : '',
        );

        if (result['success'] == true) {
          final item = result['item'] as ShopItem;
          lastBuyResults.add({
            'success': '1',
            'name': item.name,
            'target': targetOwnerId == 'user' ? 'user' : 'self',
            'reason': '',
          });
        } else {
          final reason = (result['message'] ?? '未知錯誤').toString();
          // 查一下商品名，回饋才有指向性；查不到就用 id
          String itemName = itemId;
          try {
            final rows = await db.query(
              'shop_items',
              columns: ['name'],
              where: 'id = ?',
              whereArgs: [itemId],
            );
            if (rows.isNotEmpty) itemName = rows.first['name'] as String;
          } catch (_) {}
          lastBuyResults.add({
            'success': '0',
            'name': itemName,
            'target': target,
            'reason': reason,
          });
          pendingBuyFailureNote =
              '${L.pick(en: '【System】Your attempt to buy “', zhTW: '【系統】上一輪你嘗試購買「')}$itemName${L.pick(en: '” in the previous turn failed (', zhTW: '」但沒有成功（')}$reason${L.pick(en: '). The purchase did not occur and the other person received nothing. Do not treat it as sent; move on naturally or try another way.', zhTW: '）。這筆購買未發生、對方沒有收到，不要當作已送出，可自然帶過或換個方式。')}';
        }
      }
    }

    // ═══ <pack_star>編號,編號</pack_star>：覆蓋式標記重要物品 ═══
    final starRegex = RegExp(
      r'<pack_star>([^<]*)</pack_star>',
      caseSensitive: false,
    );
    final starMatch = starRegex.allMatches(processed).toList();
    if (starMatch.isNotEmpty) {
      final ids = starMatch.last
          .group(1)!
          .split(RegExp(r'[,，、\s]+'))
          .map((e) => int.tryParse(e.replaceAll('#', '').trim()))
          .whereType<int>()
          .toList();
      await applyPackStar(characterId, ids);
    }
    processed = processed.replaceAll(starRegex, '').trim();

    // 移除所有 <buy> 標籤
    processed = processed.replaceAll(buyRegex, '').trim();
    return processed;
  }
}
