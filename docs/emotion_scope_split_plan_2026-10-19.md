# 情緒座標按模式分開（B2）施工單 — 2026-10-19

> 昭昭定案：RP 和日常**不是同一個人，是平行時空** → 每條 RP 故事線各有一份情緒，日常一份。
> 規劃：晏辭　施工：Codex　⚠️ 未真機驗證
> 規矩同 `rp_continuity_fix_plan_simple`：不加欄位、不做 migration、不新增 class／檔案。

---

## 核心做法：用「範圍 ID」代替角色 ID，資料表一欄不改

`emotion_points` / `grudge_seals` 的 `character_id` 欄位，在 RP 時存成：
```
<角色id>#rp:<continuityId>
```
日常照舊存純 `<角色id>`。

`EmotionCoordinates` 裡十幾個查詢全都是 `WHERE character_id = ?`，**只要呼叫端傳進範圍 ID，裡面一行都不用改**，RP 和日常自然分開。

### 為什麼這樣夠了
- 不動 schema、不寫 migration、備份匯出匯入原樣可用（字串照存照還原）。
- 舊資料全部留在純角色 ID 底下 = 歸日常。RP 從零開始累積。舊資料分不出哪些點來自 RP，這是唯一合理的歸屬。

---

## 步驟 1：加一個 helper（`lib/memory/emotion_coordinates.dart` 頂部，兩個靜態函式）

```dart
static const _rpScopeMark = '#rp:';

/// 日常 → 角色 id；RP → 角色 id#rp:故事線。平行時空各一份情緒。
static String scopeId(String characterId, ContextMode mode, String continuityId) =>
    mode == ContextMode.rp
        ? '$characterId$_rpScopeMark${continuityId.trim().isEmpty ? 'main' : continuityId.trim()}'
        : characterId;

/// 從範圍 ID 取回真正的角色 id（查訊息時間等非情緒表時用）。
static String baseCharacterId(String scopeId) =>
    scopeId.split(_rpScopeMark).first;
```

## 步驟 2：呼叫端改傳範圍 ID

`chat_screen_generation.dart` 在 `_ChatGenerationMethods` 裡加一個 getter：
```dart
String get _emotionScopeId => EmotionCoordinates.scopeId(
      _activeCharacterId,
      _requiredSessionIdentity.contextMode,
      _requiredSessionIdentity.continuityId,
    );
```
把以下呼叫的 `_activeCharacterId` / `charId` 換成 `_emotionScopeId`：

| 約略行號 | 呼叫 |
|---|---|
| 2820 | `EmotionCoordinates.tickDecay(...)` |
| 3092 | `EmotionCoordinates.statePrompt(...)`（文字路徑） |
| 3774 | `EmotionCoordinates.processReply(characterId: ...)` |
| 4116 | 同上（follow-up） |
| 4202 | 同上（follow-up） |
| 4933 | `EmotionCoordinates.statePrompt(...)`（圖片路徑） |
| 5287 | `EmotionCoordinates.processReply(...)`（圖片路徑） |

⚠️ 2820 那行在 `_requiredSessionIdentity` 可能尚未就緒的時機呼叫的話，用 `_sessionIdentity == null ? _activeCharacterId : _emotionScopeId` 之類的保護（以實際欄位名為準），不要讓它拋錯。

`lib/services/memory_actions.dart` 約 272 行：`EmotionCoordinates.activePoints(characterId)` 改成
`EmotionCoordinates.activePoints(EmotionCoordinates.scopeId(characterId, contextMode, continuityId))`
（`processReply` 參數裡已經有 `contextMode`、`continuityId`）。

**不用改的**：`call_screen.dart`（語音通話只在日常）、`retriever.dart:421`（蜘蛛網只在日常）、`emotion_panel.dart`（情緒面板顯示日常那份；要不要給 RP 也做一個面板，之後再說）。

## 步驟 3：`EmotionCoordinates` 內部兩處小改

1. `tickDecay`（約 564 行）：
   `DatabaseHelper.getLastMessageTime(characterId)` → `getLastMessageTime(baseCharacterId(characterId))`
   （訊息表沒有範圍 ID，要用真角色 id 查。）
2. `startupMaintenance`（約 351 行）：where 改成同時清該角色的 RP 範圍：
   ```dart
   where: "(character_id = ? OR character_id LIKE ?) "
          "AND status != 'active' AND created_at < ?",
   whereArgs: [characterId, '$characterId$_rpScopeMark%', cutoff],
   ```

## 步驟 4：刪除時連 RP 範圍一起刪（`lib/memory/database.dart`）

1. **刪角色**（約 1588、1595 行）：兩條 DELETE 的 `WHERE character_id = ?` 改成
   `WHERE (character_id = ? OR character_id LIKE ?)`，參數補 `'$id#rp:%'`。
2. **硬刪記憶**（約 4535、4540 行）：`where: 'character_id = ? AND memory_id = ?'` 改成
   `where: 'memory_id = ?'`（memory id 全域唯一，加上角色條件反而會漏掉 RP 範圍的點）。

> `'#rp:'` 這個字串在 database.dart 裡如果不想重複寫，可以用 `EmotionCoordinates` 公開一個常量；但**不要**為此新建檔案。

## 不做的事（本單範圍外）
- 刪除某條故事線時，清掉那條線的情緒：故事線目前是封存，很少真的刪，留著無害。之後有需要再加。
- RP 情緒面板。
- 把舊資料搬到 RP：分不出來源，不搬。

---

## 驗收（昭昭真機）
1. 日常聊幾句帶情緒的 → 情緒面板有變化。
2. 切到 RP，故事裡吵一架 → 回日常，情緒面板**不受影響**；日常的回覆語氣不會帶著 RP 的火氣。
3. RP 故事線 A 吵架 → 換到故事線 B，B 的情緒狀態是乾淨的。
4. 回到故事線 A，A 的火氣還在（同一個平行時空延續）。
5. 刪除一個測試角色 → 資料庫裡該角色的 `#rp:` 情緒點也被清掉（Debug 頁或匯出看）。
6. 備份匯出再匯入 → RP 的情緒還在。
