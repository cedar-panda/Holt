import 'dart:math';
import 'database.dart';
import 'retriever.dart';

class SpiderWebCore {
  static final Map<String, String> _pendingForceRecallByWindow = {};

  /// 記憶半衰期（天），預設 7 天
  static const double _halfLifeDays = 7.0;

  /// 自我揭露類別的超長半衰期（天）
  static const double _selfDisclosureHalfLifeDays = 90.0;

  /// 恩典期基礎天數
  static const int _graceBaseDays = 30;

  /// 恩典期上限天數
  static const int _graceCapDays = 90;

  /// 計算當前記憶的衰減後清晰度 (Ebbinghaus Forgetting Curve)
  /// clarity = 1.0 * (0.5) ^ (days / half_life)
  /// 自我揭露類別使用 90 天半衰期，其他用 7 天
  static double calculateClarity(
    String? lastAccessedStr, {
    String category = '',
  }) {
    final lastAccessed =
        DateTime.tryParse(lastAccessedStr ?? '') ?? DateTime.now();
    final days = DateTime.now().difference(lastAccessed).inMinutes / 1440.0;
    if (days <= 0) return 1.0;

    final halfLife = category == '自我揭露'
        ? _selfDisclosureHalfLifeDays
        : _halfLifeDays;
    return pow(0.5, days / halfLife).toDouble();
  }

  /// 計算兩條記憶的情緒共鳴距離 (Euclidean distance)
  /// 距離越小共鳴越強。0 為完全一致。最大距離為 200 * sqrt(2) ≈ 282.8
  static double calculateEmotionalResonance(
    double x1,
    double y1,
    double x2,
    double y2,
  ) {
    return sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
  }

  /// 計算孤島恩典天數 = base + floor(log2(mentionCount + 1)) × 7，上限 cap
  static int calculateGraceDays(int mentionCount) {
    final bonus = (log(mentionCount + 1) / ln2).floor() * 7;
    return min(_graceCapDays, _graceBaseDays + bonus);
  }

  /// 觸發記憶（神經傳導）
  /// 當某條記憶被提取時，呼叫此函數更新其 access 時間，並向周圍神經網路廣播提升 clarity。
  /// 同時累加 mention_count，讓恩典期計算有據可依。
  static Future<void> triggerMemory(
    int memoryId, {
    String characterId = 'default',
  }) async {
    final db = await DatabaseHelper.database;
    final nowStr = DateTime.now().toIso8601String();

    // 1. 更新本體觸發時間 + 累加 mention_count
    await db.rawUpdate(
      'UPDATE memories SET last_accessed = ?, mention_count = mention_count + 1 WHERE id = ? AND character_id = ?',
      [nowStr, memoryId, characterId],
    );

    // 2. 獲取相連的記憶 (神經傳導)
    final links = await db.query(
      'spider_web_links',
      where: 'memory_id_1 = ? OR memory_id_2 = ?',
      whereArgs: [memoryId, memoryId],
    );

    // 3. 找出相鄰節點的 ID，並更新它們的 last_accessed
    final neighborIds = <int>{};
    for (final link in links) {
      final s = link['memory_id_1'] as int;
      final t = link['memory_id_2'] as int;
      if (s != memoryId) neighborIds.add(s);
      if (t != memoryId) neighborIds.add(t);
    }

    if (neighborIds.isNotEmpty) {
      final placeholders = List.filled(neighborIds.length, '?').join(',');
      // 只傳導給 active 鄰居——已刪（status='deleted'）的殭屍節點不沾光
      await db.rawUpdate(
        "UPDATE memories SET last_accessed = ? WHERE id IN ($placeholders) AND character_id = ? AND status = 'active'",
        [nowStr, ...neighborIds, characterId],
      );
    }
  }

  /// 封存引擎：清理孤島記憶
  /// 孤島 = 沒有蛛網連線的記憶
  /// 恩典期 = f(mention_count)，被激活越多次的記憶恩典期越長
  /// 自我揭露類別永遠豁免封存
  static Future<int> runArchiveEngine({String characterId = 'default'}) async {
    final db = await DatabaseHelper.database;

    // 找出所有孤立且活躍的非永久記憶（排除自我揭露）。
    // 孤島判定只計「對端仍 active」的連線：手動刪除是軟刪
    // （status='deleted'，連線保留以便恢復時原地復活），若不過濾，
    // 死節點的殭屍連線會讓活記憶永遠不算孤島、封存引擎整個失效。
    final candidates = await db.rawQuery(
      '''
      SELECT m.id, m.content, m.mode, m.created_at, m.status,
             m.is_permanent, m.category, m.character_id,
             m.last_accessed, m.mention_count
      FROM memories m
      LEFT JOIN spider_web_links l
        ON (l.memory_id_1 = m.id AND EXISTS (
              SELECT 1 FROM memories mo
              WHERE mo.id = l.memory_id_2 AND mo.status = 'active'))
        OR (l.memory_id_2 = m.id AND EXISTS (
              SELECT 1 FROM memories mo
              WHERE mo.id = l.memory_id_1 AND mo.status = 'active'))
      WHERE m.character_id = ?
        AND m.status = 'active'
        AND m.is_permanent = 0
        AND m.category != '自我揭露'
        AND l.id IS NULL
    ''',
      [characterId],
    );

    int archivedCount = 0;
    final now = DateTime.now();

    for (final row in candidates) {
      // 用 last_accessed 判定（若為空則用 created_at）
      final lastAccessedStr = (row['last_accessed'] as String?);
      final referenceTime =
          (lastAccessedStr != null && lastAccessedStr.isNotEmpty)
          ? DateTime.tryParse(lastAccessedStr) ?? DateTime.now()
          : DateTime.tryParse(row['created_at']?.toString() ?? '') ??
                DateTime.now();

      final mentionCount = row['mention_count'] as int? ?? 0;
      final graceDays = calculateGraceDays(mentionCount);

      if (now.difference(referenceTime).inDays >= graceDays) {
        final memId = row['id'] as int;
        // 走正規封存入口
        await DatabaseHelper.archiveMemory(
          memId,
          'spider_web_decay',
          characterId: characterId,
        );
        archivedCount++;
      }
    }

    return archivedCount;
  }

  /// 處理神經網路專屬標籤：`<memo_link>` 和 `<force_recall>`
  static Future<String> processReply(
    String text, {
    String characterId = 'default',
    required String windowId,
  }) async {
    var processed = text;
    final db = await DatabaseHelper.database;

    // 1. 處理 <memo_link>id1,id2</memo_link>
    final linkRegex = RegExp(r'<memo_link>([^<]+)</memo_link>');
    final linkMatches = linkRegex.allMatches(processed).toList();
    for (final match in linkMatches) {
      final content = match.group(1)?.trim() ?? '';
      if (content.isNotEmpty) {
        // 短號 → 真 id（亂編丟棄）+ 去重（[5,5] 自環 → 永不孤島）
        final rawIds = content
            .split(',')
            .map((e) => int.tryParse(e.trim()))
            .whereType<int>()
            .map((shortNo) => Retriever.realIdFor(shortNo, windowId: windowId))
            .whereType<int>()
            .toSet()
            .toList();
        // 只接受「本角色、未刪除」的記憶 id——擋懸空邊與跨角色污染
        final ids = <int>[];
        if (rawIds.length >= 2) {
          final ph = List.filled(rawIds.length, '?').join(',');
          final valid = await db.rawQuery(
            "SELECT id FROM memories WHERE id IN ($ph) AND character_id = ? AND status = 'active'",
            [...rawIds, characterId],
          );
          ids.addAll(valid.map((r) => r['id'] as int));
        }
        if (ids.length >= 2) {
          final batch = db.batch();
          for (int i = 0; i < ids.length; i++) {
            for (int j = i + 1; j < ids.length; j++) {
              // ID 排序正規化：小的放 memory_id_1，大的放 memory_id_2
              final id1 = min(ids[i], ids[j]);
              final id2 = max(ids[i], ids[j]);
              // INSERT OR IGNORE 利用 UNIQUE(memory_id_1, memory_id_2) 去重
              batch.rawInsert(
                'INSERT OR IGNORE INTO spider_web_links (character_id, memory_id_1, memory_id_2, created_at) VALUES (?, ?, ?, ?)',
                [characterId, id1, id2, DateTime.now().toIso8601String()],
              );
            }
          }
          await batch.commit(noResult: true);
        }
      }
    }
    processed = processed.replaceAll(linkRegex, '').trim();

    // 2. 處理 <force_recall>keyword</force_recall>
    final recallRegex = RegExp(r'<force_recall>([^<]+)</force_recall>');
    final recallMatches = recallRegex.allMatches(processed).toList();
    if (recallMatches.isNotEmpty) {
      final keyword = recallMatches.last.group(1)?.trim() ?? '';
      if (keyword.isNotEmpty) {
        _pendingForceRecallByWindow[windowId] = keyword;
      }
    }
    processed = processed.replaceAll(recallRegex, '').trim();

    return processed;
  }

  /// 取出並消耗指定窗口的強行回想關鍵字。
  static String? takePendingForceRecall(String windowId) =>
      _pendingForceRecallByWindow.remove(windowId);

  static void releaseWindow(String windowId) {
    _pendingForceRecallByWindow.remove(windowId);
  }

  /// memo_merge 連線遷移：舊條們的邊全部重指到合併後的新條。
  /// 不遷移的話每次合併都在剪網——整理越勤網越碎。
  /// 舊邊清除（舊條已被合併取代，不會恢復）；oldIds 彼此間的內部邊
  /// 與會形成自環的邊直接丟棄。
  static Future<void> remapLinksAfterMerge(
    List<int> oldIds,
    int newId, {
    String characterId = 'default',
  }) async {
    if (oldIds.isEmpty) return;
    final db = await DatabaseHelper.database;
    final ph = List.filled(oldIds.length, '?').join(',');
    final edges = await db.rawQuery(
      'SELECT memory_id_1, memory_id_2 FROM spider_web_links '
      'WHERE memory_id_1 IN ($ph) OR memory_id_2 IN ($ph)',
      [...oldIds, ...oldIds],
    );
    final oldSet = oldIds.toSet();
    final batch = db.batch();
    for (final e in edges) {
      final a = e['memory_id_1'] as int;
      final b = e['memory_id_2'] as int;
      // 另一端：不在舊集合裡的那個；兩端都是舊條 = 內部邊，丟
      final other = oldSet.contains(a) ? b : a;
      if (oldSet.contains(other) || other == newId) continue;
      batch.rawInsert(
        'INSERT OR IGNORE INTO spider_web_links (character_id, memory_id_1, memory_id_2, created_at) VALUES (?, ?, ?, ?)',
        [
          characterId,
          min(newId, other),
          max(newId, other),
          DateTime.now().toIso8601String(),
        ],
      );
    }
    batch.rawDelete(
      'DELETE FROM spider_web_links WHERE memory_id_1 IN ($ph) OR memory_id_2 IN ($ph)',
      [...oldIds, ...oldIds],
    );
    await batch.commit(noResult: true);
  }
}
