# RP 連續性修復施工單（簡化版）— 2026-10-19

> 規劃：晏辭　施工：Codex　驗收：昭昭
> 取代 `rp_continuity_review_2026-10-19.md` 裡的「修復規格」段落（複核結論仍有效）。
> ⚠️ 代碼片段是**示意**，變數名以實際代碼為準；全部未真機驗證。

---

## 〇、給 Codex 的規矩（請先讀）

1. **能改一行就不改十行。** 不新增 class、不新增檔案、不抽象成通用框架、不寫 builder／strategy／policy 物件。
2. **不加資料庫欄位、不做 migration。** 本單全部步驟都不需要改 schema。如果你覺得需要，先停下來回報，不要做。
3. **沿用既有函式**：`fitRpSummaryToCharacterBudget`、`listStates`、`_isActiveForRecall`、`loadSummaryPack`、`_formatWindowSummaryPrompt`。只加參數，不重寫。
4. 每個新增的函式 ≤ 30 行；每一步一個 commit；commit 訊息寫「改了哪幾個函式」。
5. 不要順手修本單以外的東西，看到了就寫進報告。
6. 每一步做完，跑 `flutter analyze` 和 `flutter test`，失敗數不得多於上一步。

---

## 步驟 1：摘要模型收到的「現有劇情狀態」只給相關的（修 #3、➕B）

**檔案**：`lib/services/context_compressor.dart` `buildRpArchiveContext`（約 2806 行起）
**現況**：`listStates(includeNonMain: true)` 全量取前 12 條，整行（含 evidence、source ids）丟給模型。

**改法**：
```dart
final allStates = await RpStoryStateService.listStates(
  characterId,
  continuityId: continuityId,          // 只取 main 層（去掉 includeNonMain: true）
);
bool related(Map<String, dynamic> s) {
  final type = s['state_type'];
  if (type == 'scene' || type == 'plot') return true;
  return involvedKeys.contains(s['subject_entity_key']) ||
      involvedKeys.contains(s['object_entity_key']);
}
final relevant = allStates.where(related).toList();
final active = relevant.where(RpStoryStateService.isActiveForRecall);
final ended = relevant.where((s) => !RpStoryStateService.isActiveForRecall(s));
final statesForModel = [...active.take(12), ...ended.take(4)]
    .map((s) => select(s, const [
          'state_key', 'state_type', 'subject_entity_key',
          'object_entity_key', 'value', 'status', 'story_time',
        ]))
    .toList();
```
輸出那一行改成 `jsonEncode(statesForModel)`。

**連帶改動**：`rp_story_state_service.dart` 的 `_isActiveForRecall` 改名為 `isActiveForRecall`（去掉底線），同時改 415 行左右的唯一呼叫點。不要另外包一層。

**為什麼這樣夠了**：模型會看到「出場人物」的「進行中狀態＋附 key」，再加少量終態讓它知道哪些已經結束了，不會又把舊傷寫回來。

---

## 步驟 2：讓模型指認「這條取代哪條」（修 #2）

### 2a. Prompt（`lib/services/rp_summary_prompt.dart`）
zhTW 第 115 行（state_key 命名那段）後面加一句：
```
同一件事（同一傷病、同一身分、同一約定）優先沿用【現有劇情狀態】裡的 state_key。只有在必須改用新 key 時，才在 replaces_state_keys 填入被取代的舊 key（最多 3 個）；不同的傷病或不同的事不得互相取代。
```
en 第 190 行同步加：
```
Reuse an existing state_key for the same condition/identity/promise. Only if you must use a new key, list the old keys it replaces in replaces_state_keys (max 3). Never let different conditions replace each other.
```
兩處 JSON 範例（約 147、202 行）的 `story_states` 物件各加一個欄位：`"replaces_state_keys":[]`。
zhCN 如果是由 zhTW 轉換的，確認新句子也有被轉到。

### 2b. 寫入（`rp_story_state_service.dart` `storeExtraction`，約 177 行）
在算出 `key` 之後、查 `existing` 之前插入：
```dart
// 模型指認的舊 key：通過核對就「就地更新第一條、刪掉其餘重複」，
// 新 key 不再另外插入一行。
final replaces = _replacedKeys(candidate['replaces_state_keys'])
    .where((k) => k != key)
    .take(3)
    .toList();
var targetKey = key;
if (replaces.isNotEmpty) {
  final newKeyExists = (await txn.query('rp_story_states',
          columns: const ['id'],
          where: 'character_id = ? AND continuity_id = ? AND state_key = ?',
          whereArgs: [characterId, scope, key],
          limit: 1))
      .isNotEmpty;
  if (!newKeyExists) {
    final olds = await txn.query('rp_story_states',
        where: 'character_id = ? AND continuity_id = ? AND state_key IN '
            '(${List.filled(replaces.length, '?').join(',')}) '
            'AND state_type = ? AND subject_entity_key = ? '
            'AND object_entity_key = ? AND user_edited = 0',
        whereArgs: [characterId, scope, ...replaces, type, subject, object]);
    if (olds.isNotEmpty) {
      targetKey = olds.first['state_key'] as String;
      for (final dup in olds.skip(1)) {
        await txn.delete('rp_story_states',
            where: 'id = ?', whereArgs: [dup['id']]);
      }
    }
  }
}
```
之後原本用 `key` 的兩處（查 `existing`、insert 的 `state_key`）改用 `targetKey`。其餘邏輯（`user_edited` 跳過、`_latestSourceId` 不倒退）**原樣保留**，它們會自動套在 `targetKey` 那行上。

`_replacedKeys`：把 `Object?` 轉成 `List<String>`（非 List 回空、trim、去空字串），≤ 8 行。

**為什麼不加 `superseded_by` 欄位**：
- 現在同 key 的更新本來就是就地覆蓋、不留歷史，「取代」走同一條路，行為一致；
- 摘要失效時現有邏輯會刪掉 `source_summary_id` 指向它的行，就地更新的行也照樣被處理，不用新寫回滾；
- 不用 migration、不用改備份匯出匯入、不用改所有讀取點去過濾。

**已知取捨**：被刪的重複行，在「取代它的那份摘要」日後失效時不會復原。它們本來就是同一件事的重複快照，可以接受。

---

## 步驟 3：注入去重改按 key，不再按人物（修 ➕A）

**檔案**：`rp_story_state_service.dart` `_compactCurrentSnapshots`（約 336 行）
**改一個條件**：在場人物的 body/identity 改用 `state_key` 去重；不在場人物維持「每類最新一條」（省字數）。
```dart
final dedupeKey = isOffstagePerson
    ? '$type|$recallOwner'
    : (isMutableSnapshot ? '$type|$stateKey' : null);
if (dedupeKey != null && !seen.add(dedupeKey)) continue;
```
（替換原本 `if ((isMutableSnapshot || isOffstagePerson) && !seen.add('$type|$recallOwner'))` 那段。）

**注意**：舊資料裡已經存在的重複行（例如 fever / high_fever 都是 recovering）在這步之後會同時出現，直到下一次摘要用步驟 2 把它們收掉，或昭昭在劇情狀態頁手動改成 healed。**步驟 2 先上線、跑過幾次摘要，再上步驟 3。**

---

## 步驟 4：截斷時補一份最新摘要＋共用字數（修 #1、#5、➕D）

### 4a. `loadSummaryPack` 加兩個可選參數（`context_compressor.dart` 約 998 行）
```dart
int latestLimit = latestSummaryBlocksForPrompt,
int? rpKeywordMaxChars,          // 非 null 時取代內部的 getRpDynamicSummaryMaxChars()
String alreadyInjected = '',     // 已注入的摘要文字，用來去重
```
- `getLatestContextSummaries(limit: latestLimit, ...)`
- 關鍵詞召回的 `maxCharacters` 改成 `rpKeywordMaxChars ?? await getRpDynamicSummaryMaxChars()`
- `_recallKeywordSummarySegment` 加參數 `alreadyInjected`：在它算出 `fingerprint` 之後加一行
  `if (injectedFingerprint.contains(fingerprint)) continue;`
  `injectedFingerprint` 用跟 `fingerprint` 同一個正則處理 `alreadyInjected` 得到，函式開頭算一次。

### 4b. `_buildDynamicWindowSummaryPrompt`（`chat_screen_generation.dart` 約 1098 行）
非 RP 的行為**完全不變**；RP 改成「先拿最新摘要、再按剩餘預算拿關鍵詞」兩次呼叫：
```dart
final isRp = _requiredSessionIdentity.contextMode == ContextMode.rp;
final includeKeyword = useCacheKeywordRecall || useContextDynamic;

if (!isRp) {
  // 原本的單次呼叫，一字不改
}

// ── RP ──
// 本輪送出的歷史會被截斷時，才補一份最新摘要，接住被砍掉的那段
var includeLatest = false;
if (useContextDynamic) {
  final previous =
      await (_previousWindowTurnsFuture ?? Future.value(const <Message>[]));
  final limit = await MemorySettings.getContextMessageLimit();
  includeLatest = previous.length + _messages.length + 1 > limit;
}
// Cache 模式才有固定前情；上下文限制模式下這裡回傳空字串
final pinned = await _buildStaticWindowSummaryPrompt(characterId);

var latest = '';
if (includeLatest) {
  final pack = await ContextCompressor.loadSummaryPack(
    characterId,
    excludeWindowId: windowId,
    includeLatestSummaries: true,
    latestLimit: 1,
    includeKeywordRecall: false,
    contextMode: ContextMode.rp,
    continuityId: _requiredSessionIdentity.continuityId,
  );
  latest = ContextCompressor.fitRpSummaryToCharacterBudget(
    (pack['summary'] ?? '').trim(),
    1200,
  );
}

var keyword = '';
if (includeKeyword) {
  const rpTotalChars = 2000; // 三種摘要合計；先寫死，之後要調再做成設定
  final budget = max(400, rpTotalChars - pinned.length - latest.length);
  final pack = await ContextCompressor.loadSummaryPack(
    characterId,
    currentMessage: currentMessage,
    excludeWindowId: windowId,
    includeLatestSummaries: false,
    includeKeywordRecall: true,
    contextMode: ContextMode.rp,
    continuityId: _requiredSessionIdentity.continuityId,
    rpKeywordMaxChars: budget,
    alreadyInjected: '$pinned\n$latest',
  );
  keyword = (pack['keywordSummaries'] ?? '').trim();
}
return _formatWindowSummaryPrompt(summary: latest, keywordSummary: keyword);
```
- Cache 與上下文限制互斥，所以 `pinned` 和 `latest` 實際上不會同時非空；預算公式照寫即可，不用特判。
- `_buildStaticWindowSummaryPrompt` 有記憶體快照，重複呼叫不會重查資料庫。
- 不要為了省一次呼叫去重構 `loadSummaryPack`。

### 4c. 圖片路徑
`_sendImageLocked` 也是呼叫 `_buildDynamicWindowSummaryPrompt`，**不用另外改**。驗收時要測一次圖片。

### 4d. 小防呆（可選）
設定頁：若「摘要觸發條數」>「上下文條數上限」，顯示一行提示：「觸發條數大於上限時，被截掉的內容可能還沒被摘要」。不要自動改用戶的值。

---

## 步驟 5：固定前情改標籤（修 ➕C，static 區，跟其他 static 改動攢同一批）

`_formatWindowSummaryPrompt` 加參數 `bool pinned = false`。`_buildStaticWindowSummaryPrompt` 呼叫時傳 `pinned: true`。
`pinned` 為 true 且 `isRp` 時，標題文字改為：
- zhTW：`開窗前情（開窗時的快照，之後的發展以正文為準）：`
- zhCN：`开窗前情（开窗时的快照，之后的发展以正文为准）：`
- en：`Story so far (snapshot taken when this window opened; later events in the chat take precedence):`

只改這一處文字。⚠️ 會讓所有 RP 窗口的 static 前綴重建一次緩存。

---

## 驗收清單（昭昭真機）

| 步驟 | 怎麼測 | 預期 |
|---|---|---|
| 1 | Debug 頁看摘要請求的「現有劇情狀態」 | 只有出場人物＋scene/plot；每條都有 state_key；沒有 evidence |
| 2 | RP 裡讓角色發燒 → 下一批摘要寫「退燒」 | 劇情狀態頁只剩一條，狀態變成 healed，key 沿用舊的 |
| 3 | 同一角色先骨折、再發燒 | 注入裡兩條都在；發燒變成 healed 後只剩骨折 |
| 4 | 上下文限制 20 條；第 5 條埋「藥放在左邊抽屜」；第 35 條不提關鍵詞直接問「藥呢」 | 模型答得出來 |
| 4 | 同上，用**圖片**發問 | 同上 |
| 4 | Cache 模式長窗口，Debug 頁數字數 | 固定前情＋召回合計約 ≤ 2000 字；同一段劇情不會出現兩次 |
| 5 | Cache 模式開新 RP 窗口 | 標題顯示「開窗前情（…）」 |

## 施工順序
**1 → 2 →（跑幾次摘要）→ 3 → 4 → 5（併入 static 批次）**
